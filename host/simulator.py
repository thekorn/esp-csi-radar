"""Deterministic CSI source for development without hardware."""

from __future__ import annotations

import math
import random
import threading
import time
from typing import Callable

from host.protocol import CsiFrame


class CsiSimulator:
    receivers = (
        "e0:8c:fe:59:96:34",
        "e0:8c:fe:59:3f:9c",
        "b0:cb:d8:cc:c5:a8",
    )

    def __init__(self, on_frame: Callable[[CsiFrame], None], rate_hz: int = 20):
        self.on_frame = on_frame
        self.rate_hz = rate_hz
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="csi-simulator", daemon=True)
        self._started_at = time.monotonic()

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def snapshot(self) -> list[dict[str, object]]:
        devices = [
            {
                "port": "sim://tx",
                "role": "TX",
                "connected": True,
                "ready": True,
                "mac": "f4:2d:c9:6b:f2:00",
                "chip": "esp32-simulated",
                "error": None,
                "malformed": 0,
            }
        ]
        devices.extend(
            {
                "port": f"sim://rx-{index + 1}",
                "role": "RX",
                "connected": True,
                "ready": True,
                "mac": receiver,
                "chip": "esp32-simulated",
                "error": None,
                "malformed": 0,
            }
            for index, receiver in enumerate(self.receivers)
        )
        return devices

    def _run(self) -> None:
        random_source = random.Random(0xC51)
        sequences = [0, 0, 0]
        period = 1.0 / self.rate_hz
        next_frame = time.monotonic()
        while not self._stop.is_set():
            now = time.monotonic()
            elapsed = now - self._started_at
            phase = elapsed % 32.0
            occupied = 8.0 <= phase < 13.0
            for receiver_index, receiver in enumerate(self.receivers):
                samples: list[int] = []
                for subcarrier in range(64):
                    base = 34.0 + 9.0 * math.sin(subcarrier * 0.21 + receiver_index)
                    if occupied:
                        base *= 1.0 + 0.24 * math.sin(
                            elapsed * (1.4 + receiver_index * 0.15)
                            + subcarrier * 0.37
                        )
                    radio_phase = subcarrier * 0.13 + receiver_index * 0.8
                    noise = random_source.uniform(-0.8, 0.8)
                    samples.extend(
                        (
                            round(base * math.sin(radio_phase) + noise),
                            round(base * math.cos(radio_phase) + noise),
                        )
                    )
                self.on_frame(
                    CsiFrame(
                        receiver=receiver,
                        sequence=sequences[receiver_index],
                        timestamp_us=int(elapsed * 1_000_000) & 0xFFFFFFFF,
                        rssi=-43 - receiver_index * 5,
                        noise_floor=-94,
                        channel=6,
                        dropped=0,
                        samples=tuple(samples),
                    )
                )
                sequences[receiver_index] += 1
            next_frame += period
            self._stop.wait(max(0.0, next_frame - time.monotonic()))
