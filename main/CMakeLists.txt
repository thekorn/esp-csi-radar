find_program(ZIG zig REQUIRED)

set(ZIG_BUILD_FILE "${PROJECT_DIR}/build.zig")
set(ZIG_SOURCE_FILE "${CMAKE_CURRENT_SOURCE_DIR}/main.zig")
set(ZIG_INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/zig-out")
set(ZIG_OBJECT "${ZIG_INSTALL_DIR}/radar_zig.o")

if(NOT CMAKE_BUILD_EARLY_EXPANSION)
    foreach(variable ESP_NETWORK_NAME ESP_NETWORK_SECRET ESP_SERVER_HOST ESP_SERVER_PORT)
        if(NOT DEFINED ENV{${variable}} OR "$ENV{${variable}}" STREQUAL "")
            message(FATAL_ERROR "${variable} must be set when building firmware")
        endif()
    endforeach()
    if(NOT "$ENV{ESP_SERVER_PORT}" MATCHES "^[0-9]+$")
        message(FATAL_ERROR "ESP_SERVER_PORT must be an integer from 1 to 65535")
    endif()
    if($ENV{ESP_SERVER_PORT} LESS 1 OR $ENV{ESP_SERVER_PORT} GREATER 65535)
        message(FATAL_ERROR "ESP_SERVER_PORT must be an integer from 1 to 65535")
    endif()
    if("$ENV{ESP_SERVER_HOST}" MATCHES "://")
        message(FATAL_ERROR "ESP_SERVER_HOST must not include a URL scheme")
    endif()

    add_custom_command(
        OUTPUT "${ZIG_OBJECT}"
        COMMAND "${ZIG}" build
                --build-file "${ZIG_BUILD_FILE}"
                --prefix "${ZIG_INSTALL_DIR}"
                -Doptimize=ReleaseSafe
        DEPENDS "${ZIG_BUILD_FILE}" "${ZIG_SOURCE_FILE}"
        COMMENT "Building Zig application for ESP32"
        VERBATIM
    )

    set_source_files_properties("${ZIG_OBJECT}" PROPERTIES
        EXTERNAL_OBJECT TRUE
        GENERATED TRUE
    )
endif()

idf_component_register(
    SRCS "platform.c" "${ZIG_OBJECT}"
    INCLUDE_DIRS "."
    REQUIRES esp_event esp_netif esp_timer esp_websocket_client esp_wifi nvs_flash
)
