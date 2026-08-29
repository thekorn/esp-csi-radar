"""Serial discovery, role assignment, and reconnect handling."""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import serial

from host.protocol import CsiFrame, DeviceError, Hello, ProtocolError, Ready, parse_line


LOGGER = logging.getLogger(__name__)


@dataclass
class DeviceStatus:
    port: str
    configured_role: str
    connected: bool = False
    ready: bool = False
    mac: str | None = None
    chip: str | None = None
    error: str | None = None
    malformed: int = 0
    updated_at: float = field(default_factory=time.monotonic)


class DeviceConnection:
    def __init__(
        self,
        port: str,
        configured_role: str,
        baud: int,
        on_message: Callable[["DeviceConnection", object], None],
    ) -> None:
        self.status = DeviceStatus(port, configured_role)
        self.baud = baud
        self.on_message = on_message
        self.serial: serial.Serial | None = None
        self._write_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name=f"serial-{Path(port).name}", daemon=True
        )

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)
        with self._write_lock:
            if self.serial is not None:
                self.serial.close()
                self.serial = None

    def write(self, command: str) -> bool:
        payload = (command.rstrip("\r\n") + "\n").encode("ascii")
        with self._write_lock:
            if self.serial is None or not self.serial.is_open:
                return False
            try:
                self.serial.write(payload)
                self.serial.flush()
                return True
            except serial.SerialException as error:
                self.status.error = str(error)
                return False

    def _open(self) -> serial.Serial:
        connection = serial.Serial(
            self.status.port,
            self.baud,
            timeout=0.25,
            write_timeout=1.0,
            exclusive=True,
        )
        connection.dtr = False
        connection.rts = False
        return connection

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                connection = self._open()
                with self._write_lock:
                    self.serial = connection
                self.status.connected = True
                self.status.ready = False
                self.status.error = None
                self.status.updated_at = time.monotonic()
                LOGGER.info("opened %s", self.status.port)
                time.sleep(1.0)
                self.write("INFO")

                while not self._stop.is_set() and connection.is_open:
                    raw_line = connection.read_until(b"\n", 1200)
                    if not raw_line:
                        continue
                    line = raw_line.decode("ascii", errors="ignore")
                    try:
                        message = parse_line(line)
                    except ProtocolError as error:
                        self.status.malformed += 1
                        self.status.error = str(error)
                        continue
                    if message is not None:
                        self.on_message(self, message)
            except (OSError, serial.SerialException) as error:
                self.status.error = str(error)
                LOGGER.warning("%s: %s", self.status.port, error)
            finally:
                self.status.connected = False
                self.status.ready = False
                self.status.updated_at = time.monotonic()
                with self._write_lock:
                    if self.serial is not None:
                        self.serial.close()
                        self.serial = None
            self._stop.wait(1.0)


class SerialFleet:
    def __init__(
        self,
        ports: list[str],
        on_frame: Callable[[CsiFrame], None],
        channel: int = 6,
        rate_hz: int = 20,
        baud: int = 921_600,
    ) -> None:
        if len(ports) < 2:
            raise ValueError("at least one transmitter and one receiver are required")
        self.channel = channel
        self.rate_hz = rate_hz
        self.on_frame = on_frame
        self._lock = threading.RLock()
        ordered_ports = sorted(ports)
        self.connections = [
            DeviceConnection(
                port,
                "TX" if index == 0 else "RX",
                baud,
                self._on_message,
            )
            for index, port in enumerate(ordered_ports)
        ]

    def start(self) -> None:
        for connection in self.connections:
            connection.start()

    def stop(self) -> None:
        for connection in self.connections:
            connection.stop()

    def _on_message(self, connection: DeviceConnection, message: object) -> None:
        with self._lock:
            connection.status.updated_at = time.monotonic()
            if isinstance(message, Hello):
                connection.status.mac = message.mac
                connection.status.chip = message.chip
                connection.status.ready = False
                self._configure_ready_devices()
            elif isinstance(message, Ready):
                connection.status.ready = message.role == connection.status.configured_role
                connection.status.error = (
                    None if connection.status.ready else "firmware acknowledged the wrong role"
                )
            elif isinstance(message, DeviceError):
                connection.status.error = message.message
            elif isinstance(message, CsiFrame):
                if connection.status.configured_role == "RX":
                    connection.status.ready = True
                    connection.status.error = None
                self.on_frame(message)

    def _configure_ready_devices(self) -> None:
        transmitter = self.connections[0]
        if not transmitter.status.mac:
            return
        if not transmitter.status.ready:
            transmitter.write(f"ROLE,TX,{self.channel},{self.rate_hz}")
        for receiver in self.connections[1:]:
            if receiver.status.mac and not receiver.status.ready:
                receiver.write(
                    f"ROLE,RX,{self.channel},{transmitter.status.mac.replace(':', '')}"
                )

    def snapshot(self) -> list[dict[str, object]]:
        with self._lock:
            return [
                {
                    "port": status.port,
                    "role": status.configured_role,
                    "connected": status.connected,
                    "ready": status.ready,
                    "mac": status.mac,
                    "chip": status.chip,
                    "error": status.error,
                    "malformed": status.malformed,
                }
                for status in (connection.status for connection in self.connections)
            ]
