import { basename } from "node:path";
import { SerialPort } from "serialport";

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

interface DeviceStatus extends DeviceSnapshot {
  updatedAt: number;
}

type MessageHandler = (connection: DeviceConnection, message: Message) => void;

export class DeviceConnection {
  readonly status: DeviceStatus;
  readonly baud: number;
  readonly onMessage: MessageHandler;
  serial: SerialPort | null = null;
  private stopped = true;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private infoTimer: ReturnType<typeof setTimeout> | null = null;
  private receiveBuffer = "";

  constructor(port: string, configuredRole: "TX" | "RX", baud: number, onMessage: MessageHandler) {
    this.status = {
      port,
      role: configuredRole,
      connected: false,
      ready: false,
      mac: null,
      chip: null,
      error: null,
      malformed: 0,
      updatedAt: performance.now() / 1000,
    };
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
    this.clearTimers();
    const serial = this.serial;
    this.serial = null;
    this.receiveBuffer = "";
    this.markDisconnected();
    if (serial?.isOpen) {
      serial.close(() => {});
    }
  }

  write(command: string): boolean {
    const serial = this.serial;
    if (!serial?.isOpen) {
      return false;
    }
    const payload = `${command.replace(/[\r\n]+$/, "")}\n`;
    serial.write(payload, "ascii", (error) => {
      if (error) {
        this.status.error = error.message;
        return;
      }
      serial.drain((drainError) => {
        if (drainError) {
          this.status.error = drainError.message;
        }
      });
    });
    return true;
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
      console.info(`opened ${this.status.port} (${basename(this.status.port)})`);
      this.infoTimer = setTimeout(() => {
        if (this.serial === serial && serial.isOpen) {
          this.write("INFO");
        }
      }, 1000);
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
    if (this.infoTimer) {
      clearTimeout(this.infoTimer);
      this.infoTimer = null;
    }
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

  private clearTimers(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.infoTimer) {
      clearTimeout(this.infoTimer);
      this.infoTimer = null;
    }
  }
}

export class SerialFleet {
  readonly channel: number;
  readonly rateHz: number;
  readonly connections: DeviceConnection[];
  private readonly onFrame: (frame: CsiFrame) => void;

  constructor(
    ports: string[],
    onFrame: (frame: CsiFrame) => void,
    channel = 6,
    rateHz = 20,
    baud = 921_600,
  ) {
    if (ports.length < 2) {
      throw new Error("at least one transmitter and one receiver are required");
    }
    this.channel = channel;
    this.rateHz = rateHz;
    this.onFrame = onFrame;
    this.connections = [...ports]
      .sort()
      .map(
        (port, index) =>
          new DeviceConnection(port, index === 0 ? "TX" : "RX", baud, (connection, message) =>
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
    connection.status.updatedAt = performance.now() / 1000;
    switch (message.type) {
      case "hello":
        connection.status.mac = message.mac;
        connection.status.chip = message.chip;
        connection.status.ready = false;
        this.configureReadyDevices();
        break;
      case "ready":
        connection.status.ready = message.role === connection.status.role;
        connection.status.error = connection.status.ready
          ? null
          : "firmware acknowledged the wrong role";
        break;
      case "error":
        connection.status.error = message.message;
        break;
      case "csi":
        if (connection.status.role === "RX") {
          connection.status.ready = true;
          connection.status.error = null;
        }
        this.onFrame(message);
        break;
    }
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

  private configureReadyDevices(): void {
    const transmitter = this.connections[0];
    if (!transmitter.status.mac) {
      return;
    }
    if (!transmitter.status.ready) {
      transmitter.write(`ROLE,TX,${this.channel},${this.rateHz}`);
    }
    this.connections.slice(1).forEach((receiver) => {
      if (receiver.status.mac && !receiver.status.ready) {
        receiver.write(`ROLE,RX,${this.channel},${transmitter.status.mac!.replaceAll(":", "")}`);
      }
    });
  }
}
