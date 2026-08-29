/* Thin ESP-IDF and FreeRTOS interoperability layer for the Zig application. */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_timer.h"
#include "esp_websocket_client.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#define CSI_MAX_BYTES 384
#define CSI_QUEUE_LENGTH 12
#define WIFI_CONNECTED_BIT BIT0
#define WEBSOCKET_URI_MAX 280
#define WEBSOCKET_SEND_TIMEOUT_MS 100

typedef struct {
    uint32_t timestamp_us;
    uint32_t dropped;
    int8_t rssi;
    int8_t noise_floor;
    uint8_t channel;
    uint16_t length;
    int8_t data[CSI_MAX_BYTES];
} csi_record_t;

static const char *TAG = "csi_radar";
static const uint8_t broadcast_mac[6] = {
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
};
static uint8_t transmitter_mac[6];
static QueueHandle_t csi_queue;
static uint32_t pending_drops;
static esp_netif_t *station_netif;
static EventGroupHandle_t wifi_events;
static bool station_should_connect;
static esp_websocket_client_handle_t websocket_client;

static void wifi_event(void *context, esp_event_base_t event_base,
                       int32_t event_id, void *event_data)
{
    (void)context;
    (void)event_data;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED &&
        station_should_connect) {
        xEventGroupClearBits(wifi_events, WIFI_CONNECTED_BIT);
        ESP_LOGW(TAG, "Wi-Fi disconnected; reconnecting");
        esp_err_t result = esp_wifi_connect();
        if (result != ESP_OK) {
            ESP_LOGE(TAG, "Wi-Fi reconnect failed: %s",
                     esp_err_to_name(result));
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        xEventGroupSetBits(wifi_events, WIFI_CONNECTED_BIT);
    }
}

static void websocket_event(void *context, esp_event_base_t event_base,
                            int32_t event_id, void *event_data)
{
    (void)context;
    (void)event_base;
    (void)event_data;
    switch ((esp_websocket_event_id_t)event_id) {
    case WEBSOCKET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "WebSocket connected");
        break;
    case WEBSOCKET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "WebSocket disconnected; reconnecting");
        break;
    case WEBSOCKET_EVENT_ERROR:
        ESP_LOGE(TAG, "WebSocket transport error");
        break;
    default:
        break;
    }
}

static void check_nvs(void)
{
    esp_err_t result = nvs_flash_init();
    if (result == ESP_ERR_NVS_NO_FREE_PAGES ||
        result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        result = nvs_flash_init();
    }
    ESP_ERROR_CHECK(result);
}

void platform_init(void)
{
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);

    check_nvs();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    station_netif = esp_netif_create_default_wifi_sta();
    if (station_netif == NULL) {
        ESP_LOGE(TAG, "Failed to create the Wi-Fi station interface");
        abort();
    }
    wifi_events = xEventGroupCreate();
    if (wifi_events == NULL) {
        ESP_LOGE(TAG, "Failed to create the Wi-Fi event group");
        abort();
    }
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               &wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               &wifi_event, NULL));

    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&config));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_LOGI(TAG, "Wi-Fi initialized; starting autonomous radar");
}

void platform_get_mac(uint8_t output[6])
{
    ESP_ERROR_CHECK(esp_wifi_get_mac(WIFI_IF_STA, output));
}

uint8_t platform_connect_wifi(const uint8_t *network_name,
                              uint8_t network_name_length,
                              const uint8_t *network_secret,
                              uint8_t network_secret_length,
                              const uint8_t *hostname,
                              uint8_t hostname_length, uint8_t *channel)
{
    if (network_name_length == 0 || network_name_length > 32 ||
        network_secret_length < 8 || network_secret_length > 64 ||
        hostname_length == 0 || hostname_length > 32) {
        return 0;
    }

    char hostname_text[33] = {0};
    memcpy(hostname_text, hostname, hostname_length);
    wifi_config_t config = {0};
    memcpy(config.sta.ssid, network_name, network_name_length);
    memcpy(config.sta.password, network_secret, network_secret_length);

    if (esp_netif_set_hostname(station_netif, hostname_text) != ESP_OK ||
        esp_wifi_set_config(WIFI_IF_STA, &config) != ESP_OK) {
        return 0;
    }

    xEventGroupClearBits(wifi_events, WIFI_CONNECTED_BIT);
    station_should_connect = true;
    if (esp_wifi_connect() != ESP_OK) {
        station_should_connect = false;
        return 0;
    }
    xEventGroupWaitBits(wifi_events, WIFI_CONNECTED_BIT, pdFALSE, pdTRUE,
                        portMAX_DELAY);

    wifi_second_chan_t secondary_channel;
    if (esp_wifi_get_channel(channel, &secondary_channel) != ESP_OK) {
        return 0;
    }
    ESP_LOGI(TAG, "Connected to Wi-Fi as %s on channel %u", hostname_text,
             *channel);
    return 1;
}

uint8_t platform_start_websocket(const uint8_t *server_host,
                                 uint16_t server_host_length,
                                 uint16_t server_port)
{
    if (server_host_length == 0 || server_host_length > 253 ||
        server_port == 0) {
        return 0;
    }

    char uri[WEBSOCKET_URI_MAX];
    int uri_length = snprintf(uri, sizeof(uri), "ws://%.*s:%u/device",
                              (int)server_host_length,
                              (const char *)server_host,
                              (unsigned int)server_port);
    if (uri_length < 0 || uri_length >= (int)sizeof(uri)) {
        return 0;
    }

    esp_websocket_client_config_t config = {
        .uri = uri,
        .disable_auto_reconnect = false,
        .reconnect_timeout_ms = 5000,
        .network_timeout_ms = 5000,
    };
    websocket_client = esp_websocket_client_init(&config);
    if (websocket_client == NULL) {
        return 0;
    }
    if (esp_websocket_register_events(websocket_client, WEBSOCKET_EVENT_ANY,
                                      &websocket_event, NULL) != ESP_OK ||
        esp_websocket_client_start(websocket_client) != ESP_OK) {
        ESP_ERROR_CHECK(esp_websocket_client_destroy(websocket_client));
        websocket_client = NULL;
        return 0;
    }
    return 1;
}

uint8_t platform_start_tx(void)
{
    ESP_ERROR_CHECK(esp_wifi_set_bandwidth(WIFI_IF_STA, WIFI_BW_HT20));
    if (esp_now_init() != ESP_OK) {
        return 0;
    }

    esp_now_peer_info_t peer = {0};
    memcpy(peer.peer_addr, broadcast_mac, sizeof(broadcast_mac));
    peer.channel = 0;
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false;
    if (esp_now_add_peer(&peer) != ESP_OK) {
        return 0;
    }

    esp_now_rate_config_t rate = {
        .phymode = WIFI_PHY_MODE_HT20,
        .rate = WIFI_PHY_RATE_MCS0_LGI,
        .ersu = false,
        .dcm = false,
    };
    if (esp_now_set_peer_rate_config(broadcast_mac, &rate) != ESP_OK) {
        return 0;
    }
    return 1;
}

uint8_t platform_send_probe(const uint8_t *data, uint16_t length)
{
    return esp_now_send(broadcast_mac, data, length) == ESP_OK;
}

static void csi_receive(void *context, wifi_csi_info_t *info)
{
    (void)context;
    if (info == NULL || info->buf == NULL || info->len == 0 ||
        memcmp(info->mac, transmitter_mac, sizeof(transmitter_mac)) != 0) {
        return;
    }

    uint16_t offset = info->first_word_invalid && info->len >= 4 ? 4 : 0;
    uint16_t length = info->len - offset;
    if (length > CSI_MAX_BYTES) {
        length = CSI_MAX_BYTES;
    }

    csi_record_t record = {
        .timestamp_us = info->rx_ctrl.timestamp,
        .dropped = pending_drops,
        .rssi = info->rx_ctrl.rssi,
        .noise_floor = info->rx_ctrl.noise_floor,
        .channel = info->rx_ctrl.channel,
        .length = length,
    };
    memcpy(record.data, info->buf + offset, length);

    if (xQueueSend(csi_queue, &record, 0) == pdTRUE) {
        pending_drops = 0;
    } else {
        pending_drops++;
    }
}

uint8_t platform_start_rx(const uint8_t tx_mac[6])
{
    ESP_ERROR_CHECK(esp_wifi_set_bandwidth(WIFI_IF_STA, WIFI_BW_HT20));
    if (esp_now_init() != ESP_OK) {
        return 0;
    }
    memcpy(transmitter_mac, tx_mac, sizeof(transmitter_mac));
    csi_queue = xQueueCreate(CSI_QUEUE_LENGTH, sizeof(csi_record_t));
    if (csi_queue == NULL) {
        return 0;
    }

    wifi_csi_config_t config = {
        .lltf_en = true,
        .htltf_en = true,
        .stbc_htltf2_en = false,
        .ltf_merge_en = true,
        .channel_filter_en = true,
        .manu_scale = false,
        .shift = 0,
    };
    if (esp_wifi_set_promiscuous(true) != ESP_OK ||
        esp_wifi_set_csi_config(&config) != ESP_OK ||
        esp_wifi_set_csi_rx_cb(csi_receive, NULL) != ESP_OK ||
        esp_wifi_set_csi(true) != ESP_OK) {
        return 0;
    }
    return 1;
}

uint8_t platform_csi_read(int8_t *data, uint16_t capacity, uint16_t *length,
                          uint32_t *timestamp_us, int8_t *rssi,
                          int8_t *noise_floor, uint8_t *channel,
                          uint32_t *dropped)
{
    csi_record_t record;
    if (xQueueReceive(csi_queue, &record, 0) != pdTRUE) {
        return 0;
    }

    uint16_t output_length = record.length < capacity ? record.length : capacity;
    memcpy(data, record.data, output_length);
    *length = output_length;
    *timestamp_us = record.timestamp_us;
    *rssi = record.rssi;
    *noise_floor = record.noise_floor;
    *channel = record.channel;
    *dropped = record.dropped;
    return 1;
}

void platform_write(const uint8_t *data, uint16_t length)
{
    fwrite(data, 1, length, stdout);
    if (websocket_client != NULL &&
        esp_websocket_client_is_connected(websocket_client)) {
        esp_websocket_client_send_text(websocket_client, (const char *)data,
                                       length,
                                       pdMS_TO_TICKS(WEBSOCKET_SEND_TIMEOUT_MS));
    }
}

uint64_t platform_millis(void)
{
    return esp_timer_get_time() / 1000;
}

void platform_delay_ms(uint32_t delay_ms)
{
    vTaskDelay(pdMS_TO_TICKS(delay_ms));
}
