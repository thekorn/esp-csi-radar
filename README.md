# ESP CSI room radar

A four-device room sensing demo that detects changes caused by people without
using a camera or microphone. One ESP32 broadcasts fixed-rate ESP-NOW probes;
three ESP32 receivers collect channel state information (CSI) and stream it to
a Linux host. The host calibrates an empty-room radio fingerprint, detects
sustained changes across the three links, and serves a live web visualization.

```text
                         ESP-NOW probes, channel 6
                                  ┌────────┐
                                  │ ESP32  │
                                  │ TX · 1 │
                                  └───┬────┘
                         ┌────────────┼────────────┐
                         ▼            ▼            ▼
                    ┌────────┐   ┌────────┐   ┌────────┐
                    │ ESP32  │   │ ESP32  │   │ ESP32  │
                    │ RX · 2 │   │ RX · 3 │   │ RX · 4 │
                    └───┬────┘   └───┬────┘   └───┬────┘
                        └──── USB serial to Linux ─┘
                                      │
                              detector + web UI
```

All boards use the same Zig firmware. The host assigns the first serial port
as transmitter and the remaining ports as receivers at boot.

## Hardware

The checked hardware on `thekorn-server-2` is four homogeneous
ESP32-D0WD-V3 revision 3.1 devices with 4 MB flash and CP2102 USB-UART bridges:

| Port | Role | Factory MAC |
| --- | --- | --- |
| `/dev/esp32-1` | Transmitter | `f4:2d:c9:6b:f2:00` |
| `/dev/esp32-2` | Receiver 1 | `e0:8c:fe:59:96:34` |
| `/dev/esp32-3` | Receiver 2 | `e0:8c:fe:59:3f:9c` |
| `/dev/esp32-4` | Receiver 3 | `b0:cb:d8:cc:c5:a8` |

For useful sensing, fix the four devices in place with the transmitter on one
side of the room and receivers spread around the opposite perimeter. Keep each
device at least one metre from the transmitter, use a consistent antenna
orientation, and keep USB cables from moving during calibration or detection.

## Development environment

[Nix flakes](https://nixos.org/) provide ESP-IDF, an Xtensa-capable Zig build,
Python with pyserial, ZLS, nixd, and Codebook:

```sh
nix develop
```

Commands can also be run without entering a shell:

```sh
nix develop .#setup -c zig build test
nix develop .#setup -c python -m unittest discover -s host/tests -v
nix develop .#setup -c idf.py build
nix develop .#setup -c codebook-lsp lint --unique -s .
```

The project follows the Zig/ESP-IDF boundary used by
[`thekorn/esp32-flappy-bird`](https://github.com/thekorn/esp32-flappy-bird):
Zig produces the application object, while ESP-IDF owns SDK integration,
linking, image generation, and flashing. `main/platform.c` is only a thin
SDK and FreeRTOS adapter; radio role behavior, commands, probe construction,
and output framing live in `main/main.zig`.

## Run without hardware

The simulator exercises the detector, HTTP API, server-sent events, and every
visualization state. It alternates between an empty and changed radio field:

```sh
nix develop .#setup -c python -m host.server --simulate --bind 0.0.0.0
```

Open `http://localhost:8080` when running locally. The first empty-room
calibration takes about four seconds; simulated presence begins after eight
seconds.

Inside an Amp orb, `amp orb services ensure` starts the same simulator as a
supervised service and prints its authenticated portal URL.

## Flash and run the real demo

On `thekorn-server-2`, build and flash the same image to every board:

```sh
nix develop .#setup -c idf.py build
nix develop .#setup -c ./scripts/flash-all.sh
```

Then start the host service:

```sh
nix develop .#setup -c python -m host.server --bind 0.0.0.0 \
  --ports /dev/esp32-1 /dev/esp32-2 /dev/esp32-3 /dev/esp32-4
```

The service opens all ports at 921600 baud. It assigns `/dev/esp32-1` as TX,
passes its live MAC to each receiver as a CSI source filter, and begins
streaming at 20 Hz on Wi-Fi channel 6.

Leave the room empty while the initial baseline reaches 100%. Use **Calibrate**
in the web page any time sensor placement, furniture, or the RF channel
changes. The API is intentionally small:

- `GET /api/state` — current detector, link, and device state;
- `GET /api/events` — live server-sent event stream;
- `GET /api/health` — ready receiver count;
- `POST /api/calibrate` — reset the empty-room baseline.

## Detection model and limits

Each CSI vector is converted from interleaved imaginary/real samples into
subcarrier amplitudes and normalized by RMS energy to reduce automatic-gain
changes. Calibration learns one baseline and noise threshold per receiver.
Three consecutive threshold crossings activate a link; room occupancy is held
for 20 seconds after the most recent active frame.

This is a sensing demo, not a safety or security system. It observes three
independent bistatic Wi-Fi links—not a phase-synchronized radar. Placement,
people, doors, fans, furniture, RF interference, antenna motion, and temperature
all affect the signal. The baseline-sensitive detector can retain a stationary
person's changed fingerprint, but no CSI-only threshold detector can guarantee
stationary-person presence in every room. Calibrate and tune using representative
occupied, empty, and nuisance data before relying on its output.

## Repository layout

- `main/` — Zig application and thin ESP-IDF C adapter;
- `host/` — serial protocol, detector, simulator, and HTTP service;
- `web/` — dependency-free responsive visualization;
- `scripts/flash-all.sh` — ESP-IDF-driven four-board flashing;
- `flake.nix` — pinned development toolchain;
- `codebook.toml` — project-local spelling dictionary.
