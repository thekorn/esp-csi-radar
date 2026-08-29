import type { DeviceSnapshot } from "./devices.ts";
import type { CsiFrame } from "./protocol.ts";

const RECEIVERS = ["e0:8c:fe:59:96:34", "e0:8c:fe:59:3f:9c", "b0:cb:d8:cc:c5:a8"] as const;

function seededRandom(seed: number): () => number {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let value = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    value = (value + Math.imul(value ^ (value >>> 7), 61 | value)) ^ value;
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

export class CsiSimulator {
  readonly rateHz: number;
  private readonly onFrame: (frame: CsiFrame) => void;
  private readonly startedAt = performance.now() / 1000;
  private readonly random = seededRandom(0xc51);
  private readonly sequences = [0, 0, 0];
  private stopped = true;
  private nextFrame = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(onFrame: (frame: CsiFrame) => void, rateHz = 20) {
    this.onFrame = onFrame;
    this.rateHz = rateHz;
  }

  start(): void {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    this.nextFrame = performance.now() / 1000;
    this.run();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  snapshot(): DeviceSnapshot[] {
    return [
      {
        port: "sim://tx",
        role: "TX",
        connected: true,
        ready: true,
        mac: "f4:2d:c9:6b:f2:00",
        chip: "esp32-simulated",
        error: null,
        malformed: 0,
      },
      ...RECEIVERS.map((receiver, index): DeviceSnapshot => ({
        port: `sim://rx-${index + 1}`,
        role: "RX",
        connected: true,
        ready: true,
        mac: receiver,
        chip: "esp32-simulated",
        error: null,
        malformed: 0,
      })),
    ];
  }

  private run(): void {
    if (this.stopped) {
      return;
    }
    const now = performance.now() / 1000;
    const elapsed = now - this.startedAt;
    const phase = elapsed % 32;
    const occupied = phase >= 8 && phase < 13;

    RECEIVERS.forEach((receiver, receiverIndex) => {
      const samples: number[] = [];
      for (let subcarrier = 0; subcarrier < 64; subcarrier += 1) {
        let base = 34 + 9 * Math.sin(subcarrier * 0.21 + receiverIndex);
        if (occupied) {
          base *= 1 + 0.24 * Math.sin(elapsed * (1.4 + receiverIndex * 0.15) + subcarrier * 0.37);
        }
        const radioPhase = subcarrier * 0.13 + receiverIndex * 0.8;
        const noise = this.random() * 1.6 - 0.8;
        samples.push(
          Math.round(base * Math.sin(radioPhase) + noise),
          Math.round(base * Math.cos(radioPhase) + noise),
        );
      }
      this.onFrame({
        type: "csi",
        receiver,
        sequence: this.sequences[receiverIndex],
        timestampUs: Math.floor(elapsed * 1_000_000) % 0x1_0000_0000,
        rssi: -43 - receiverIndex * 5,
        noiseFloor: -94,
        channel: 6,
        dropped: 0,
        samples,
      });
      this.sequences[receiverIndex] += 1;
    });

    this.nextFrame += 1 / this.rateHz;
    this.timer = setTimeout(
      () => this.run(),
      Math.max(0, this.nextFrame - performance.now() / 1000) * 1000,
    );
  }
}
