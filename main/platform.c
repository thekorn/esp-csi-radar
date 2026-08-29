/* Thin ESP-IDF and FreeRTOS interoperability layer for the Zig application. */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#define CSI_MAX_BYTES 384
#define CSI_QUEUE_LENGTH 12

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

    wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&config));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_LOGI(TAG, "Wi-Fi initialized; waiting for a role command");
}

void platform_get_mac(uint8_t output[6])
{
    ESP_ERROR_CHECK(esp_wifi_get_mac(WIFI_IF_STA, output));
}

static void set_radio_channel(uint8_t channel)
{
    ESP_ERROR_CHECK(esp_wifi_set_bandwidth(WIFI_IF_STA, WIFI_BW_HT20));
    ESP_ERROR_CHECK(esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE));
}

uint8_t platform_start_tx(uint8_t channel)
{
    set_radio_channel(channel);
    if (esp_now_init() != ESP_OK) {
        return 0;
    }

    esp_now_peer_info_t peer = {0};
    memcpy(peer.peer_addr, broadcast_mac, sizeof(broadcast_mac));
    peer.channel = channel;
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

uint8_t platform_start_rx(uint8_t channel, const uint8_t tx_mac[6])
{
    set_radio_channel(channel);
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

int32_t platform_read_char(void)
{
    return getchar();
}

void platform_write(const uint8_t *data, uint16_t length)
{
    fwrite(data, 1, length, stdout);
}

uint64_t platform_millis(void)
{
    return esp_timer_get_time() / 1000;
}

void platform_delay_ms(uint32_t delay_ms)
{
    vTaskDelay(pdMS_TO_TICKS(delay_ms));
}
