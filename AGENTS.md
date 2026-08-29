# Project guidance

## Architecture

- The demo uses one ESP32 as an ESP-NOW probe transmitter and three ESP32s as
  CSI receivers. The Linux host assigns roles from the stable serial-port
  order, so all four boards run the same firmware image.
- Keep firmware behavior in Zig. `main/main.zig` owns command parsing,
  role behavior, probe creation, and serial framing. Keep
  `main/platform.c` limited to ESP-IDF and FreeRTOS interoperability.
- Keep sensing and occupancy decisions in the Bun/TypeScript code under
  `host/`. The browser only renders state received from the host API.
- Put durable ESP-IDF settings in `sdkconfig.defaults`. Treat `sdkconfig`,
  `build/`, `managed_components/`, and `zig-out/` as generated state.

## Development and verification

- Use the Nix flake development environment; do not rely on globally installed
  ESP-IDF, Zig, Bun packages, or Codebook.
- Before every commit, run all three required checks:

  ```sh
  nix develop .#setup -c bun run typecheck
  nix develop .#setup -c bun run lint
  nix develop .#setup -c bun run format:check
  ```

- Build firmware with `nix develop .#setup -c idf.py build`.
- Run checks with `nix develop .#setup -c zig build test`,
  `nix develop .#setup -c bun test`, and
  `nix develop .#setup -c codebook-lsp lint --unique -s .`.
- Use `nix flake check --no-build` after changing the flake.
- Verify firmware builds before accessing hardware. Report build verification
  separately from physical-device verification.

## Real hardware

- Real-device access must use the Amp runner named `thekorn-server-2`. The
  four boards are exposed as `/dev/esp32-1` through `/dev/esp32-4`.
- Resolve the runner immediately before hardware work because runner IDs are
  ephemeral. Confirm every chip matches the firmware target before flashing.
- Flash with ESP-IDF-generated artifacts and parameters. Do not hard-code
  flash offsets.
- Capture startup output and check for ESP-IDF errors, panics, resets, role
  acknowledgements, and CSI records. Do not claim sensing validation based on
  a successful firmware build alone.
- Apply the repository `Caddyfile` to the running Caddy instance from the
  repository root on `thekorn-server-2` with:

  ```sh
  set -o pipefail
  caddy adapt --config Caddyfile --adapter caddyfile |
    curl --fail-with-body --silent --show-error \
      --request POST \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      http://127.0.0.1:2019/load
  ```

  The admin API replaces the complete live Caddy configuration. Review the
  file before applying it if other routes have changed. This host starts Caddy
  from a NixOS-generated config, so reapply after a Caddy restart, reload, or
  NixOS switch until the route is represented in the declarative host config.
