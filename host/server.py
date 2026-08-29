"""HTTP/SSE visualization server and serial ingest entry point."""

from __future__ import annotations

import argparse
import json
import logging
import mimetypes
import signal
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Protocol
from urllib.parse import urlparse

from host.detector import RoomDetector
from host.devices import SerialFleet
from host.protocol import CsiFrame
from host.simulator import CsiSimulator


WEB_ROOT = Path(__file__).resolve().parent.parent / "web"
LOGGER = logging.getLogger(__name__)


class Source(Protocol):
    rate_hz: int

    def start(self) -> None: ...

    def stop(self) -> None: ...

    def snapshot(self) -> list[dict[str, object]]: ...


class RadarApplication:
    def __init__(self, detector: RoomDetector, source: Source, mode: str):
        self.detector = detector
        self.source = source
        self.mode = mode
        self.started_at = time.monotonic()

    def ingest(self, frame: CsiFrame) -> None:
        self.detector.ingest(frame)

    def snapshot(self) -> dict[str, object]:
        state = self.detector.snapshot()
        state.update(
            {
                "mode": self.mode,
                "sampleRateHz": self.source.rate_hz,
                "uptimeSeconds": round(time.monotonic() - self.started_at, 1),
                "devices": self.source.snapshot(),
            }
        )
        return state


class RadarHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], application: RadarApplication):
        self.application = application
        super().__init__(address, RadarRequestHandler)


class RadarRequestHandler(BaseHTTPRequestHandler):
    server: RadarHttpServer
    protocol_version = "HTTP/1.1"

    def log_message(self, message: str, *args: object) -> None:
        if getattr(self, "path", None) != "/api/events":
            LOGGER.info("%s - %s", self.client_address[0], message % args)

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlparse(self.path).path
        if path == "/api/state":
            self._send_json(self.server.application.snapshot())
            return
        if path == "/api/health":
            snapshot = self.server.application.snapshot()
            ready_receivers = sum(
                device["role"] == "RX" and device["ready"]
                for device in snapshot["devices"]
            )
            self._send_json(
                {
                    "ok": ready_receivers >= 1,
                    "readyReceivers": ready_receivers,
                    "state": snapshot["state"],
                },
                HTTPStatus.OK if ready_receivers >= 1 else HTTPStatus.SERVICE_UNAVAILABLE,
            )
            return
        if path == "/api/events":
            self._send_events()
            return
        self._send_static(path)

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlparse(self.path).path
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length:
            self.rfile.read(content_length)
        if path == "/api/calibrate":
            self.server.application.detector.reset()
            self._send_json({"ok": True}, HTTPStatus.ACCEPTED)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def _send_json(
        self, payload: object, status: HTTPStatus = HTTPStatus.OK
    ) -> None:
        body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_events(self) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        event_id = 0
        try:
            while True:
                payload = json.dumps(
                    self.server.application.snapshot(),
                    separators=(",", ":"),
                    allow_nan=False,
                )
                event = f"id: {event_id}\ndata: {payload}\n\n".encode()
                self.wfile.write(event)
                self.wfile.flush()
                event_id += 1
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_static(self, path: str) -> None:
        relative_path = "index.html" if path == "/" else path.lstrip("/")
        candidate = (WEB_ROOT / relative_path).resolve()
        if WEB_ROOT not in candidate.parents or not candidate.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = candidate.read_bytes()
        content_type, _ = mimetypes.guess_type(candidate.name)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header(
            "Cache-Control", "no-cache" if candidate.suffix == ".html" else "public, max-age=300"
        )
        self.end_headers()
        self.wfile.write(body)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1", help="HTTP bind address")
    parser.add_argument("--port", type=int, default=8080, help="HTTP port")
    parser.add_argument("--channel", type=int, default=6, choices=range(1, 14))
    parser.add_argument("--rate", type=int, default=20, choices=range(1, 101))
    parser.add_argument("--baud", type=int, default=921_600)
    parser.add_argument(
        "--ports",
        nargs="+",
        default=[f"/dev/esp32-{index}" for index in range(1, 5)],
        help="serial ports; sorted first port becomes transmitter",
    )
    parser.add_argument(
        "--simulate", action="store_true", help="generate CSI instead of opening serial ports"
    )
    parser.add_argument("--calibration-samples", type=int, default=80)
    parser.add_argument("--hold-seconds", type=float, default=20.0)
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    logging.basicConfig(
        level=logging.DEBUG if arguments.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    detector = RoomDetector(arguments.calibration_samples, arguments.hold_seconds)

    application: RadarApplication
    if arguments.simulate:
        source = CsiSimulator(detector.ingest, arguments.rate)
        application = RadarApplication(detector, source, "simulation")
    else:
        source = SerialFleet(
            arguments.ports,
            detector.ingest,
            channel=arguments.channel,
            rate_hz=arguments.rate,
            baud=arguments.baud,
        )
        application = RadarApplication(detector, source, "hardware")

    server = RadarHttpServer((arguments.bind, arguments.port), application)
    shutdown_started = threading.Event()

    def request_shutdown(_signal: int, _frame: object) -> None:
        if shutdown_started.is_set():
            return
        shutdown_started.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)
    source.start()
    LOGGER.info(
        "serving %s mode on http://%s:%d",
        application.mode,
        arguments.bind,
        arguments.port,
    )
    try:
        server.serve_forever()
    finally:
        source.stop()
        server.server_close()


if __name__ == "__main__":
    main()
