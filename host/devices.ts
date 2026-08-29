import { SerialPort } from "serialport";
import type { RawData, WebSocket } from "ws";

import { ProtocolError, parseLine, type CsiFrame, type Message } from "./protocol.ts";

export interface DeviceSnapshot {
  port: string;
  role: "TX" | "RX";
  connected: boolean;
  ready: boolean;
  mac: string | null;
  chip: string | null;
  error: string | null;
  malformed: number;
}

interface HardwareDevice {
  name: string;
  role: "TX" | "RX";
  mac: string;
}

export const HARDWARE_DEVICES: readonly HardwareDevice[] = [
  { name: "esp32-1", role: "TX", mac: "f4:2d:c9:6b:f2:00" },
  { name: "esp32-2", role: "RX", mac: "e0:8c:fe:59:96:34" },
  { name: "esp32-3", role: "RX", mac: "e0:8c:fe:59:3f:9c" },
  { name: "esp32-4", role: "RX", mac: "b0:cb:d8:cc:c5:a8" },
];

interface DeviceStatus extends DeviceSnapshot {
  updatedAt: number;
}

function createStatus(device: HardwareDevice, port: string): DeviceStatus {
  return {
    port,
    role: device.role,
    connected: false,
    ready: false,
    mac: device.mac,
    chip: null,
    error: null,
    malformed: 0,
    updatedAt: performance.now() / 1000,
  };
}

function applyMessage(
  status: DeviceStatus,
  message: Message,
  onFrame: (frame: CsiFrame) => void,
): void {
  status.updatedAt = performance.now() / 1000;
  switch (message.type) {
    case "hello":
      if (message.mac !== status.mac) {
        status.ready = false;
        status.error = `expected ${status.mac}, received ${message.mac}`;
        return;
      }
      status.chip = message.chip;
      status.error = null;
      break;
    case "ready":
      status.ready = message.role === status.role && message.mac === status.mac;
      status.error = status.ready ? null : "firmware acknowledged the wrong identity or role";
      break;
    case "error":
      status.error = message.message;
      break;
    case "csi":
      if (status.role !== "RX" || message.receiver !== status.mac) {
        status.error = "received CSI for the wrong device";
        return;
      }
      status.ready = true;
      status.error = null;
      onFrame(message);
      break;
  }
}

type MessageHandler = (connection: DeviceConnection, message: Message) => void;

export class DeviceConnection {
  readonly status: DeviceStatus;
  readonly baud: number;
  readonly onMessage: MessageHandler;
  serial: SerialPort | null = null;
  private stopped = true;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private receiveBuffer = "";

  constructor(port: string, device: HardwareDevice, baud: number, onMessage: MessageHandler) {
    this.status = createStatus(device, port);
    this.baud = baud;
    this.onMessage = onMessage;
  }

  start(): void {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    this.open();
  }

  stop(): void {
    this.stopped = true;
    this.clearReconnectTimer();
    const serial = this.serial;
    this.serial = null;
    this.receiveBuffer = "";
    this.markDisconnected();
    if (serial?.isOpen) {
      serial.close(() => {});
    }
  }

  private open(): void {
    if (this.stopped) {
      return;
    }
    const serial = new SerialPort({
      path: this.status.port,
      baudRate: this.baud,
      autoOpen: false,
      lock: true,
    });
    this.serial = serial;
    serial.on("data", (chunk: Buffer) => {
      if (this.serial === serial) {
        this.handleData(chunk);
      }
    });
    serial.on("error", (error: Error) => {
      if (this.serial !== serial) {
        return;
      }
      this.status.error = error.message;
      console.warn(`${this.status.port}: ${error.message}`);
    });
    serial.on("close", () => this.handleClose(serial));
    serial.open((error) => {
      if (this.stopped || this.serial !== serial) {
        if (!error && serial.isOpen) {
          serial.close(() => {});
        }
        return;
      }
      if (error) {
        this.status.error = error.message;
        console.warn(`${this.status.port}: ${error.message}`);
        this.serial = null;
        this.markDisconnected();
        this.scheduleReconnect();
        return;
      }
      serial.set({ dtr: false, rts: false }, (setError) => {
        if (setError) {
          this.status.error = setError.message;
        }
      });
      this.receiveBuffer = "";
      this.status.connected = true;
      this.status.ready = false;
      this.status.error = null;
      this.status.updatedAt = performance.now() / 1000;
      console.info(`opened ${this.status.port}`);
    });
  }

  private handleData(chunk: Buffer): void {
    this.receiveBuffer += chunk.toString("ascii");
    while (true) {
      const newline = this.receiveBuffer.indexOf("\n");
      if (newline < 0 && this.receiveBuffer.length < 1200) {
        return;
      }
      const end = newline < 0 ? 1200 : newline + 1;
      const line = this.receiveBuffer.slice(0, end);
      this.receiveBuffer = this.receiveBuffer.slice(end);
      try {
        const message = parseLine(line);
        if (message) {
          this.onMessage(this, message);
        }
      } catch (error) {
        if (!(error instanceof ProtocolError)) {
          throw error;
        }
        this.status.malformed += 1;
        this.status.error = error.message;
      }
    }
  }

  private handleClose(serial: SerialPort): void {
    if (this.serial !== serial) {
      return;
    }
    this.serial = null;
    this.receiveBuffer = "";
    this.markDisconnected();
    this.scheduleReconnect();
  }

  private markDisconnected(): void {
    this.status.connected = false;
    this.status.ready = false;
    this.status.updatedAt = performance.now() / 1000;
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) {
      return;
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.open();
    }, 1000);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }
}

export class SerialFleet {
  readonly rateHz: number;
  readonly connections: DeviceConnection[];
  private readonly onFrame: (frame: CsiFrame) => void;

  constructor(ports: string[], onFrame: (frame: CsiFrame) => void, rateHz = 20, baud = 921_600) {
    if (ports.length < 2 || ports.length > HARDWARE_DEVICES.length) {
      throw new Error("between two and four serial ports are required");
    }
    this.rateHz = rateHz;
    this.onFrame = onFrame;
    this.connections = [...ports]
      .sort()
      .map(
        (port, index) =>
          new DeviceConnection(port, HARDWARE_DEVICES[index], baud, (connection, message) =>
            this.handleMessage(connection, message),
          ),
      );
  }

  start(): void {
    this.connections.forEach((connection) => connection.start());
  }

  stop(): void {
    this.connections.forEach((connection) => connection.stop());
  }

  handleMessage(connection: DeviceConnection, message: Message): void {
    applyMessage(connection.status, message, this.onFrame);
  }

  snapshot(): DeviceSnapshot[] {
    return this.connections.map(({ status }) => ({
      port: status.port,
      role: status.role,
      connected: status.connected,
      ready: status.ready,
      mac: status.mac,
      chip: status.chip,
      error: status.error,
      malformed: status.malformed,
    }));
  }
}

type RadarSocket = WebSocket;

function decodeTextMessage(data: RawData): string {
  if (Array.isArray(data)) {
    return Buffer.concat(data).toString("utf8");
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf8");
  }
  return data.toString("utf8");
}

function messageMac(message: Message): string | null {
  switch (message.type) {
    case "hello":
    case "ready":
      return message.mac;
    case "csi":
      return message.receiver;
    case "error":
      return null;
  }
}

export class SocketFleet {
  readonly rateHz: number;
  private readonly onFrame: (frame: CsiFrame) => void;
  private readonly statuses = new Map<string, DeviceStatus>();
  private readonly sockets = new Map<string, RadarSocket>();
  private readonly identities = new WeakMap<RadarSocket, string>();
  private stopped = true;

  constructor(onFrame: (frame: CsiFrame) => void, rateHz = 20) {
    this.onFrame = onFrame;
    this.rateHz = rateHz;
    HARDWARE_DEVICES.forEach((device) => {
      this.statuses.set(device.mac, createStatus(device, `ws://${device.name}`));
    });
  }

  start(): void {
    this.stopped = false;
  }

  stop(): void {
    this.stopped = true;
    this.sockets.forEach((socket) => socket.close(1001, "server stopping"));
    this.sockets.clear();
    this.statuses.forEach((status) => {
      status.connected = false;
      status.ready = false;
    });
  }

  snapshot(): DeviceSnapshot[] {
    return HARDWARE_DEVICES.map((device) => {
      const status = this.statuses.get(device.mac)!;
      return {
        port: status.port,
        role: status.role,
        connected: status.connected,
        ready: status.ready,
        mac: status.mac,
        chip: status.chip,
        error: status.error,
        malformed: status.malformed,
      };
    });
  }

  accept(socket: RadarSocket): void {
    if (this.stopped) {
      socket.close(1012, "socket ingestion is stopped");
      return;
    }
    socket.on("message", (data, isBinary) => {
      if (isBinary) {
        socket.close(1003, "text records required");
        return;
      }
      this.handleSocketMessage(socket, decodeTextMessage(data));
    });
    socket.once("close", () => this.closeSocket(socket));
  }

  handleSocketMessage(socket: RadarSocket, raw: string): void {
    let message: Message | null;
    try {
      message = parseLine(raw);
    } catch (error) {
      if (!(error instanceof ProtocolError)) {
        throw error;
      }
      const identity = this.identities.get(socket);
      const status = identity ? this.statuses.get(identity) : null;
      if (status) {
        status.malformed += 1;
        status.error = error.message;
      } else {
        socket.close(1008, "invalid radar record");
      }
      return;
    }
    if (!message) {
      return;
    }

    const identity = messageMac(message);
    if (identity && !this.associate(socket, identity)) {
      return;
    }
    const associatedMac = this.identities.get(socket);
    if (!associatedMac) {
      socket.close(1008, "device identity required");
      return;
    }
    const status = this.statuses.get(associatedMac)!;
    applyMessage(status, message, this.onFrame);
  }

  closeSocket(socket: RadarSocket): void {
    const mac = this.identities.get(socket);
    if (!mac || this.sockets.get(mac) !== socket) {
      return;
    }
    this.sockets.delete(mac);
    const status = this.statuses.get(mac)!;
    status.connected = false;
    status.ready = false;
    status.updatedAt = performance.now() / 1000;
  }

  private associate(socket: RadarSocket, mac: string): boolean {
    const status = this.statuses.get(mac);
    const identity = this.identities.get(socket);
    if (!status || (identity && identity !== mac)) {
      socket.close(1008, "unknown or inconsistent device identity");
      return false;
    }
    if (!identity) {
      const previous = this.sockets.get(mac);
      if (previous && previous !== socket) {
        previous.close(4000, "replaced by reconnect");
      }
      this.identities.set(socket, mac);
      this.sockets.set(mac, socket);
      status.connected = true;
      status.error = null;
      status.updatedAt = performance.now() / 1000;
    }
    return true;
  }
}
