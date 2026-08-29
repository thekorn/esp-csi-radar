"""Gain-resistant CSI baseline detector for the room demo."""

from __future__ import annotations

import math
import statistics
import threading
import time
from collections import deque
from dataclasses import dataclass, field

from host.protocol import CsiFrame


def _normalized_amplitudes(samples: tuple[int, ...]) -> list[float]:
    amplitudes = [
        math.hypot(samples[index], samples[index + 1])
        for index in range(0, len(samples), 2)
    ]
    rms = math.sqrt(sum(value * value for value in amplitudes) / len(amplitudes))
    if rms < 1e-6:
        return []
    return [value / rms for value in amplitudes]


@dataclass
class LinkState:
    receiver: str
    calibration_samples: int
    baseline: list[float] = field(default_factory=list)
    calibration_count: int = 0
    calibration_deviations: list[float] = field(default_factory=list)
    threshold: float = 0.055
    score: float = 0.0
    active: bool = False
    hit_streak: int = 0
    clear_streak: int = 0
    frames: int = 0
    dropped: int = 0
    rssi: int = 0
    noise_floor: int = 0
    channel: int = 0
    last_sequence: int | None = None
    last_seen: float = 0.0
    history: deque[float] = field(default_factory=lambda: deque(maxlen=120))

    @property
    def calibrated(self) -> bool:
        return self.calibration_count >= self.calibration_samples

    def reset_shape(self, vector: list[float]) -> None:
        self.baseline = vector.copy()
        self.calibration_count = 1
        self.calibration_deviations.clear()
        self.threshold = 0.055
        self.score = 0.0
        self.active = False
        self.hit_streak = 0
        self.clear_streak = 0
        self.history.clear()

    def ingest(self, frame: CsiFrame, now: float) -> bool:
        vector = _normalized_amplitudes(frame.samples)
        if len(vector) < 8:
            return False

        self.frames += 1
        self.dropped += frame.dropped
        if self.last_sequence is not None:
            expected = (self.last_sequence + 1) & 0xFFFFFFFF
            if frame.sequence != expected:
                gap = (frame.sequence - expected) & 0xFFFFFFFF
                # A small forward gap is loss. A large modular gap means the
                # receiver rebooted and restarted its local sequence counter.
                if gap < 1_000_000:
                    self.dropped += gap
        self.last_sequence = frame.sequence
        self.rssi = frame.rssi
        self.noise_floor = frame.noise_floor
        self.channel = frame.channel
        self.last_seen = now

        if len(vector) != len(self.baseline):
            self.reset_shape(vector)
            return False

        deviation = math.sqrt(
            sum((value - mean) ** 2 for value, mean in zip(vector, self.baseline))
            / len(vector)
        )

        if not self.calibrated:
            self.calibration_count += 1
            alpha = 1.0 / self.calibration_count
            for index, value in enumerate(vector):
                self.baseline[index] += alpha * (value - self.baseline[index])
            if self.calibration_count > 5:
                self.calibration_deviations.append(deviation)
            if self.calibrated:
                mean = statistics.fmean(self.calibration_deviations)
                spread = (
                    statistics.pstdev(self.calibration_deviations)
                    if len(self.calibration_deviations) > 1
                    else 0.0
                )
                self.threshold = max(0.055, mean + 5.0 * spread)
            self.score = 0.0
            self.history.append(0.0)
            return False

        raw_score = deviation / self.threshold
        self.score = 0.7 * self.score + 0.3 * raw_score
        self.history.append(min(self.score, 4.0))

        if self.score >= 1.0:
            self.hit_streak += 1
            self.clear_streak = 0
            if self.hit_streak >= 3:
                self.active = True
        elif self.score < 0.55:
            self.hit_streak = 0
            self.clear_streak += 1
            if self.clear_streak >= 8:
                self.active = False
        else:
            self.hit_streak = max(0, self.hit_streak - 1)
            self.clear_streak = 0

        if not self.active and self.score < 0.7:
            for index, value in enumerate(vector):
                self.baseline[index] += 0.001 * (value - self.baseline[index])
        return self.active


class RoomDetector:
    """Combines independent CSI links into one held occupancy state."""

    def __init__(self, calibration_samples: int = 80, hold_seconds: float = 20.0):
        if calibration_samples < 10:
            raise ValueError("calibration_samples must be at least 10")
        self.calibration_samples = calibration_samples
        self.hold_seconds = hold_seconds
        self.links: dict[str, LinkState] = {}
        self.last_activity: float | None = None
        self.generation = 0
        self._lock = threading.RLock()

    def ingest(self, frame: CsiFrame, now: float | None = None) -> None:
        instant = time.monotonic() if now is None else now
        with self._lock:
            link = self.links.get(frame.receiver)
            if link is None:
                link = LinkState(frame.receiver, self.calibration_samples)
                self.links[frame.receiver] = link
            if link.ingest(frame, instant):
                self.last_activity = instant

    def reset(self) -> None:
        with self._lock:
            self.links.clear()
            self.last_activity = None
            self.generation += 1

    def snapshot(self, now: float | None = None) -> dict[str, object]:
        instant = time.monotonic() if now is None else now
        with self._lock:
            live_links = [
                link for link in self.links.values() if instant - link.last_seen <= 2.0
            ]
            all_calibrated = bool(live_links) and all(
                link.calibrated for link in live_links
            )
            occupied = (
                all_calibrated
                and self.last_activity is not None
                and instant - self.last_activity <= self.hold_seconds
            )
            if not live_links:
                state = "offline"
            elif not all_calibrated:
                state = "calibrating"
            elif occupied:
                state = "occupied"
            else:
                state = "clear"

            links = []
            for link in sorted(self.links.values(), key=lambda item: item.receiver):
                links.append(
                    {
                        "receiver": link.receiver,
                        "calibrated": link.calibrated,
                        "calibration": min(
                            1.0, link.calibration_count / link.calibration_samples
                        ),
                        "active": link.active,
                        "score": round(link.score, 3),
                        "rssi": link.rssi,
                        "noiseFloor": link.noise_floor,
                        "channel": link.channel,
                        "frames": link.frames,
                        "dropped": link.dropped,
                        "lastSeenSeconds": round(instant - link.last_seen, 2),
                        "history": [round(value, 3) for value in link.history],
                    }
                )

            return {
                "state": state,
                "occupied": occupied,
                "score": round(max((link.score for link in live_links), default=0.0), 3),
                "calibration": round(
                    min(
                        (link.calibration_count / link.calibration_samples for link in live_links),
                        default=0.0,
                    ),
                    3,
                ),
                "holdRemainingSeconds": round(
                    max(
                        0.0,
                        self.hold_seconds
                        - (instant - self.last_activity)
                        if self.last_activity is not None
                        else 0.0,
                    ),
                    1,
                ),
                "generation": self.generation,
                "links": links,
            }
