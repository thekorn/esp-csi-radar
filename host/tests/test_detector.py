from __future__ import annotations

import math
import unittest

from host.detector import RoomDetector
from host.protocol import CsiFrame


def frame(sequence: int, changed: bool = False, scale: float = 1.0) -> CsiFrame:
    samples: list[int] = []
    for subcarrier in range(32):
        amplitude = 35.0 + 8.0 * math.sin(subcarrier * 0.31)
        if changed:
            amplitude *= 1.0 + 0.35 * math.sin(subcarrier * 0.73)
        samples.extend(
            [
                round(scale * amplitude * math.sin(subcarrier * 0.17)),
                round(scale * amplitude * math.cos(subcarrier * 0.17)),
            ]
        )
    return CsiFrame(
        receiver="e0:8c:fe:59:96:34",
        sequence=sequence,
        timestamp_us=sequence * 50_000,
        rssi=-45,
        noise_floor=-94,
        channel=6,
        dropped=0,
        samples=tuple(samples),
    )


class DetectorTests(unittest.TestCase):
    def test_calibrates_and_detects_changed_channel_shape(self) -> None:
        detector = RoomDetector(calibration_samples=12, hold_seconds=3.0)
        for sequence in range(12):
            detector.ingest(frame(sequence), now=sequence * 0.05)

        self.assertEqual(detector.snapshot(now=0.6)["state"], "clear")
        for sequence in range(12, 18):
            detector.ingest(frame(sequence, changed=True), now=sequence * 0.05)

        snapshot = detector.snapshot(now=0.9)
        self.assertEqual(snapshot["state"], "occupied")
        self.assertTrue(snapshot["links"][0]["active"])
        self.assertGreater(snapshot["score"], 1.0)
        self.assertEqual(detector.snapshot(now=4.1)["state"], "offline")

    def test_normalizes_uniform_gain_changes(self) -> None:
        detector = RoomDetector(calibration_samples=12, hold_seconds=3.0)
        for sequence in range(12):
            detector.ingest(frame(sequence), now=sequence * 0.05)
        for sequence in range(12, 22):
            detector.ingest(frame(sequence, scale=1.7), now=sequence * 0.05)

        snapshot = detector.snapshot(now=1.1)
        self.assertEqual(snapshot["state"], "clear")
        self.assertLess(snapshot["score"], 1.0)

    def test_reset_requires_fresh_calibration(self) -> None:
        detector = RoomDetector(calibration_samples=10)
        for sequence in range(10):
            detector.ingest(frame(sequence), now=sequence * 0.05)
        detector.reset()
        self.assertEqual(detector.snapshot(now=0.5)["state"], "offline")
        self.assertEqual(detector.snapshot(now=0.5)["generation"], 1)


if __name__ == "__main__":
    unittest.main()
