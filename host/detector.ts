import type { CsiFrame } from "./protocol.ts";

const HISTORY_LENGTH = 120;
const UINT32_MODULUS = 0x1_0000_0000;

function normalizedAmplitudes(samples: readonly number[]): number[] {
  const amplitudes: number[] = [];
  for (let index = 0; index < samples.length; index += 2) {
    amplitudes.push(Math.hypot(samples[index], samples[index + 1]));
  }
  const rms = Math.sqrt(
    amplitudes.reduce((sum, value) => sum + value * value, 0) / amplitudes.length,
  );
  if (rms < 1e-6) {
    return [];
  }
  return amplitudes.map((value) => value / rms);
}

function round(value: number, digits: number): number {
  return Number(value.toFixed(digits));
}

export class LinkState {
  readonly receiver: string;
  readonly calibrationSamples: number;
  baseline: number[] = [];
  calibrationCount = 0;
  calibrationDeviations: number[] = [];
  threshold = 0.055;
  score = 0;
  active = false;
  hitStreak = 0;
  clearStreak = 0;
  frames = 0;
  dropped = 0;
  rssi = 0;
  noiseFloor = 0;
  channel = 0;
  lastSequence: number | null = null;
  lastSeen = 0;
  history: number[] = [];

  constructor(receiver: string, calibrationSamples: number) {
    this.receiver = receiver;
    this.calibrationSamples = calibrationSamples;
  }

  get calibrated(): boolean {
    return this.calibrationCount >= this.calibrationSamples;
  }

  resetShape(vector: number[]): void {
    this.baseline = [...vector];
    this.calibrationCount = 1;
    this.calibrationDeviations = [];
    this.threshold = 0.055;
    this.score = 0;
    this.active = false;
    this.hitStreak = 0;
    this.clearStreak = 0;
    this.history = [];
  }

  ingest(frame: CsiFrame, now: number): boolean {
    const vector = normalizedAmplitudes(frame.samples);
    if (vector.length < 8) {
      return false;
    }

    this.frames += 1;
    this.dropped += frame.dropped;
    if (this.lastSequence !== null) {
      const expected = (this.lastSequence + 1) % UINT32_MODULUS;
      if (frame.sequence !== expected) {
        const gap = (frame.sequence - expected + UINT32_MODULUS) % UINT32_MODULUS;
        if (gap < 1_000_000) {
          this.dropped += gap;
        }
      }
    }
    this.lastSequence = frame.sequence;
    this.rssi = frame.rssi;
    this.noiseFloor = frame.noiseFloor;
    this.channel = frame.channel;
    this.lastSeen = now;

    if (vector.length !== this.baseline.length) {
      this.resetShape(vector);
      return false;
    }

    const deviation = Math.sqrt(
      vector.reduce((sum, value, index) => {
        const difference = value - this.baseline[index];
        return sum + difference * difference;
      }, 0) / vector.length,
    );

    if (!this.calibrated) {
      this.calibrationCount += 1;
      const alpha = 1 / this.calibrationCount;
      vector.forEach((value, index) => {
        this.baseline[index] += alpha * (value - this.baseline[index]);
      });
      if (this.calibrationCount > 5) {
        this.calibrationDeviations.push(deviation);
      }
      if (this.calibrated) {
        const mean =
          this.calibrationDeviations.reduce((sum, value) => sum + value, 0) /
          this.calibrationDeviations.length;
        const spread =
          this.calibrationDeviations.length > 1
            ? Math.sqrt(
                this.calibrationDeviations.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
                  this.calibrationDeviations.length,
              )
            : 0;
        this.threshold = Math.max(0.055, mean + 5 * spread);
      }
      this.score = 0;
      this.appendHistory(0);
      return false;
    }

    const rawScore = deviation / this.threshold;
    this.score = 0.7 * this.score + 0.3 * rawScore;
    this.appendHistory(Math.min(this.score, 4));

    if (this.score >= 1) {
      this.hitStreak += 1;
      this.clearStreak = 0;
      if (this.hitStreak >= 3) {
        this.active = true;
      }
    } else if (this.score < 0.55) {
      this.hitStreak = 0;
      this.clearStreak += 1;
      if (this.clearStreak >= 8) {
        this.active = false;
      }
    } else {
      this.hitStreak = Math.max(0, this.hitStreak - 1);
      this.clearStreak = 0;
    }

    if (!this.active && this.score < 0.7) {
      vector.forEach((value, index) => {
        this.baseline[index] += 0.001 * (value - this.baseline[index]);
      });
    }
    return this.active;
  }

  private appendHistory(value: number): void {
    this.history.push(value);
    if (this.history.length > HISTORY_LENGTH) {
      this.history.shift();
    }
  }
}

export interface LinkSnapshot {
  receiver: string;
  calibrated: boolean;
  calibration: number;
  active: boolean;
  score: number;
  rssi: number;
  noiseFloor: number;
  channel: number;
  frames: number;
  dropped: number;
  lastSeenSeconds: number;
  history: number[];
}

export interface DetectorSnapshot {
  state: "offline" | "calibrating" | "occupied" | "clear";
  occupied: boolean;
  score: number;
  calibration: number;
  holdRemainingSeconds: number;
  generation: number;
  links: LinkSnapshot[];
}

/** Combines independent CSI links into one held occupancy state. */
export class RoomDetector {
  readonly calibrationSamples: number;
  readonly holdSeconds: number;
  readonly links = new Map<string, LinkState>();
  lastActivity: number | null = null;
  generation = 0;

  constructor(calibrationSamples = 80, holdSeconds = 20) {
    if (calibrationSamples < 10) {
      throw new Error("calibrationSamples must be at least 10");
    }
    this.calibrationSamples = calibrationSamples;
    this.holdSeconds = holdSeconds;
  }

  ingest(frame: CsiFrame, now = performance.now() / 1000): void {
    let link = this.links.get(frame.receiver);
    if (!link) {
      link = new LinkState(frame.receiver, this.calibrationSamples);
      this.links.set(frame.receiver, link);
    }
    if (link.ingest(frame, now)) {
      this.lastActivity = now;
    }
  }

  reset(): void {
    this.links.clear();
    this.lastActivity = null;
    this.generation += 1;
  }

  snapshot(now = performance.now() / 1000): DetectorSnapshot {
    const allLinks = [...this.links.values()];
    const liveLinks = allLinks.filter((link) => now - link.lastSeen <= 2);
    const allCalibrated = liveLinks.length > 0 && liveLinks.every((link) => link.calibrated);
    const occupied =
      allCalibrated && this.lastActivity !== null && now - this.lastActivity <= this.holdSeconds;

    let state: DetectorSnapshot["state"];
    if (liveLinks.length === 0) {
      state = "offline";
    } else if (!allCalibrated) {
      state = "calibrating";
    } else if (occupied) {
      state = "occupied";
    } else {
      state = "clear";
    }

    const links = allLinks
      .sort((left, right) => left.receiver.localeCompare(right.receiver))
      .map((link): LinkSnapshot => ({
        receiver: link.receiver,
        calibrated: link.calibrated,
        calibration: Math.min(1, link.calibrationCount / link.calibrationSamples),
        active: link.active,
        score: round(link.score, 3),
        rssi: link.rssi,
        noiseFloor: link.noiseFloor,
        channel: link.channel,
        frames: link.frames,
        dropped: link.dropped,
        lastSeenSeconds: round(now - link.lastSeen, 2),
        history: link.history.map((value) => round(value, 3)),
      }));

    const score = Math.max(0, ...liveLinks.map((link) => link.score));
    const calibration =
      liveLinks.length === 0
        ? 0
        : Math.min(...liveLinks.map((link) => link.calibrationCount / link.calibrationSamples));
    const holdRemaining =
      this.lastActivity === null ? 0 : Math.max(0, this.holdSeconds - (now - this.lastActivity));

    return {
      state,
      occupied,
      score: round(score, 3),
      calibration: round(calibration, 3),
      holdRemainingSeconds: round(holdRemaining, 1),
      generation: this.generation,
      links,
    };
  }
}
