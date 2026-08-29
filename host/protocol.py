"""Line protocol shared with the ESP32 firmware."""

from __future__ import annotations

from dataclasses import dataclass


class ProtocolError(ValueError):
    """Raised when a RADAR line is present but malformed."""


@dataclass(frozen=True)
class Hello:
    mac: str
    chip: str


@dataclass(frozen=True)
class Ready:
    role: str
    fields: tuple[str, ...]


@dataclass(frozen=True)
class DeviceError:
    message: str


@dataclass(frozen=True)
class CsiFrame:
    receiver: str
    sequence: int
    timestamp_us: int
    rssi: int
    noise_floor: int
    channel: int
    dropped: int
    samples: tuple[int, ...]


Message = Hello | Ready | DeviceError | CsiFrame


def normalize_mac(value: str) -> str:
    compact = value.replace(":", "").replace("-", "").lower()
    if len(compact) != 12:
        raise ProtocolError("MAC address must contain 12 hexadecimal digits")
    try:
        bytes.fromhex(compact)
    except ValueError as error:
        raise ProtocolError("MAC address is not hexadecimal") from error
    return ":".join(compact[index : index + 2] for index in range(0, 12, 2))


def parse_line(line: str) -> Message | None:
    """Parse a firmware record, ignoring ESP-IDF logs and empty lines."""

    stripped = line.strip()
    if not stripped or not stripped.startswith("RADAR,"):
        return None

    parts = stripped.split(",")
    if len(parts) < 2:
        raise ProtocolError("record has no type")

    message_type = parts[1]
    if message_type == "HELLO":
        if len(parts) != 4:
            raise ProtocolError("HELLO requires MAC and chip")
        return Hello(normalize_mac(parts[2]), parts[3])
    if message_type == "READY":
        if len(parts) < 4 or parts[2] not in {"TX", "RX"}:
            raise ProtocolError("READY has an invalid role")
        return Ready(parts[2], tuple(parts[3:]))
    if message_type == "ERROR":
        if len(parts) != 3:
            raise ProtocolError("ERROR requires one message")
        return DeviceError(parts[2])
    if message_type != "CSI":
        return None
    if len(parts) != 11:
        raise ProtocolError("CSI requires nine metadata fields and a payload")

    try:
        receiver = normalize_mac(parts[2])
        sequence = int(parts[3])
        timestamp_us = int(parts[4])
        rssi = int(parts[5])
        noise_floor = int(parts[6])
        channel = int(parts[7])
        dropped = int(parts[8])
        declared_length = int(parts[9])
        raw_samples = bytes.fromhex(parts[10])
    except ValueError as error:
        raise ProtocolError("CSI contains invalid numeric or hexadecimal data") from error

    if declared_length != len(raw_samples):
        raise ProtocolError(
            f"CSI payload length is {len(raw_samples)}, expected {declared_length}"
        )
    if declared_length == 0 or declared_length % 2 != 0:
        raise ProtocolError("CSI payload must contain complete I/Q pairs")
    if not 1 <= channel <= 13:
        raise ProtocolError("CSI channel is outside the supported 2.4 GHz range")
    if dropped < 0:
        raise ProtocolError("CSI dropped count cannot be negative")

    samples = tuple(value if value < 128 else value - 256 for value in raw_samples)
    return CsiFrame(
        receiver=receiver,
        sequence=sequence,
        timestamp_us=timestamp_us,
        rssi=rssi,
        noise_floor=noise_floor,
        channel=channel,
        dropped=dropped,
        samples=samples,
    )
