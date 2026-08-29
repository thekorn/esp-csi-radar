from __future__ import annotations

import unittest

from host.devices import SerialFleet
from host.protocol import CsiFrame


class SerialFleetTests(unittest.TestCase):
    def test_valid_csi_confirms_receiver_is_ready_and_recovers_error(self) -> None:
        frames: list[CsiFrame] = []
        fleet = SerialFleet(["/dev/esp32-1", "/dev/esp32-2"], frames.append)
        receiver = fleet.connections[1]
        receiver.status.error = "transient malformed line"
        receiver.status.malformed = 1
        frame = CsiFrame(
            receiver="e0:8c:fe:59:96:34",
            sequence=1,
            timestamp_us=50_000,
            rssi=-45,
            noise_floor=-96,
            channel=6,
            dropped=0,
            samples=(1, 2) * 8,
        )

        fleet._on_message(receiver, frame)

        self.assertTrue(receiver.status.ready)
        self.assertIsNone(receiver.status.error)
        self.assertEqual(receiver.status.malformed, 1)
        self.assertEqual(frames, [frame])


if __name__ == "__main__":
    unittest.main()
