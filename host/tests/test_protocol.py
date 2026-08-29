from __future__ import annotations

import unittest

from host.protocol import CsiFrame, Hello, ProtocolError, parse_line


class ProtocolTests(unittest.TestCase):
    def test_ignores_esp_idf_logs(self) -> None:
        self.assertIsNone(parse_line("I (328) wifi:mode : sta"))

    def test_parses_hello(self) -> None:
        self.assertEqual(
            parse_line("RADAR,HELLO,F42DC96BF200,esp32\n"),
            Hello("f4:2d:c9:6b:f2:00", "esp32"),
        )

    def test_parses_signed_csi(self) -> None:
        message = parse_line(
            "RADAR,CSI,e0:8c:fe:59:96:34,7,1234,-47,-94,6,2,4,00ff7f80"
        )
        self.assertIsInstance(message, CsiFrame)
        assert isinstance(message, CsiFrame)
        self.assertEqual(message.samples, (0, -1, 127, -128))
        self.assertEqual(message.dropped, 2)

    def test_rejects_truncated_payload(self) -> None:
        with self.assertRaisesRegex(ProtocolError, "payload length"):
            parse_line("RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,8,00ff")


if __name__ == "__main__":
    unittest.main()
