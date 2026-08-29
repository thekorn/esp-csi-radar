export class ProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProtocolError";
  }
}

export interface Hello {
  type: "hello";
  mac: string;
  chip: string;
}

export interface Ready {
  type: "ready";
  role: "TX" | "RX";
  mac: string;
  channel: number;
  detail: string;
}

export interface DeviceError {
  type: "error";
  message: string;
}

export interface CsiFrame {
  type: "csi";
  receiver: string;
  sequence: number;
  timestampUs: number;
  rssi: number;
  noiseFloor: number;
  channel: number;
  dropped: number;
  samples: number[];
}

export type Message = Hello | Ready | DeviceError | CsiFrame;

export function normalizeMac(value: string): string {
  const compact = value.replaceAll(":", "").replaceAll("-", "").toLowerCase();
  if (compact.length !== 12) {
    throw new ProtocolError("MAC address must contain 12 hexadecimal digits");
  }
  if (!/^[0-9a-f]{12}$/.test(compact)) {
    throw new ProtocolError("MAC address is not hexadecimal");
  }
  return compact.match(/.{2}/g)!.join(":");
}

function parseInteger(value: string): number {
  if (!/^[+-]?\d+$/.test(value)) {
    throw new Error("invalid integer");
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error("integer is outside the supported range");
  }
  return parsed;
}

/** Parse a firmware record, ignoring ESP-IDF logs and empty lines. */
export function parseLine(line: string): Message | null {
  const stripped = line.trim();
  if (!stripped || !stripped.startsWith("RADAR,")) {
    return null;
  }

  const parts = stripped.split(",");
  if (parts.length < 2) {
    throw new ProtocolError("record has no type");
  }

  const messageType = parts[1];
  if (messageType === "HELLO") {
    if (parts.length !== 4) {
      throw new ProtocolError("HELLO requires MAC and chip");
    }
    return { type: "hello", mac: normalizeMac(parts[2]), chip: parts[3] };
  }
  if (messageType === "READY") {
    if (parts.length !== 6 || (parts[2] !== "TX" && parts[2] !== "RX")) {
      throw new ProtocolError("READY has an invalid role");
    }
    let channel: number;
    try {
      channel = parseInteger(parts[4]);
    } catch {
      throw new ProtocolError("READY contains an invalid channel");
    }
    if (channel < 1 || channel > 13) {
      throw new ProtocolError("READY channel is outside the supported 2.4 GHz range");
    }
    return {
      type: "ready",
      role: parts[2],
      mac: normalizeMac(parts[3]),
      channel,
      detail: parts[5],
    };
  }
  if (messageType === "ERROR") {
    if (parts.length !== 3) {
      throw new ProtocolError("ERROR requires one message");
    }
    return { type: "error", message: parts[2] };
  }
  if (messageType !== "CSI") {
    return null;
  }
  if (parts.length !== 11) {
    throw new ProtocolError("CSI requires nine metadata fields and a payload");
  }

  let receiver: string;
  let sequence: number;
  let timestampUs: number;
  let rssi: number;
  let noiseFloor: number;
  let channel: number;
  let dropped: number;
  let declaredLength: number;
  let rawSamples: number[];
  try {
    receiver = normalizeMac(parts[2]);
    sequence = parseInteger(parts[3]);
    timestampUs = parseInteger(parts[4]);
    rssi = parseInteger(parts[5]);
    noiseFloor = parseInteger(parts[6]);
    channel = parseInteger(parts[7]);
    dropped = parseInteger(parts[8]);
    declaredLength = parseInteger(parts[9]);
    if (parts[10].length % 2 !== 0 || !/^[0-9a-f]*$/i.test(parts[10])) {
      throw new Error("invalid hexadecimal data");
    }
    rawSamples = parts[10].match(/.{2}/g)?.map((value) => Number.parseInt(value, 16)) ?? [];
  } catch {
    throw new ProtocolError("CSI contains invalid numeric or hexadecimal data");
  }

  if (declaredLength !== rawSamples.length) {
    throw new ProtocolError(
      `CSI payload length is ${rawSamples.length}, expected ${declaredLength}`,
    );
  }
  if (declaredLength === 0 || declaredLength % 2 !== 0) {
    throw new ProtocolError("CSI payload must contain complete I/Q pairs");
  }
  if (channel < 1 || channel > 13) {
    throw new ProtocolError("CSI channel is outside the supported 2.4 GHz range");
  }
  if (dropped < 0) {
    throw new ProtocolError("CSI dropped count cannot be negative");
  }

  const samples = rawSamples.map((value) => (value < 128 ? value : value - 256));
  return {
    type: "csi",
    receiver,
    sequence,
    timestampUs,
    rssi,
    noiseFloor,
    channel,
    dropped,
    samples,
  };
}
