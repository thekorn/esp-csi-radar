#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
devices=(
  /dev/esp32-1
  /dev/esp32-2
  /dev/esp32-3
  /dev/esp32-4
)

if [[ ! -f "$repo_root/build/flasher_args.json" ]]; then
  echo "Firmware has not been built; running idf.py build"
  idf.py -C "$repo_root" build
fi

for device in "${devices[@]}"; do
  if [[ ! -c "$device" ]]; then
    echo "Expected serial device is missing: $device" >&2
    exit 1
  fi
done

for device in "${devices[@]}"; do
  echo "Flashing $device"
  idf.py -C "$repo_root" -p "$device" -b 921600 flash
done

echo "Flashed the shared radar firmware to all four ESP32 devices."
