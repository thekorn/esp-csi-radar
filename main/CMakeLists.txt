find_program(ZIG zig REQUIRED)

set(ZIG_BUILD_FILE "${PROJECT_DIR}/build.zig")
set(ZIG_SOURCE_FILE "${CMAKE_CURRENT_SOURCE_DIR}/main.zig")
set(ZIG_INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/zig-out")
set(ZIG_OBJECT "${ZIG_INSTALL_DIR}/radar_zig.o")

if(NOT CMAKE_BUILD_EARLY_EXPANSION)
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
    REQUIRES esp_event esp_netif esp_timer esp_wifi nvs_flash
)
