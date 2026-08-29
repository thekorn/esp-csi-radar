import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { RoomDetector } from "../detector.ts";
import type { CsiFrame } from "../protocol.ts";

function frame(sequence: number, changed = false, scale = 1): CsiFrame {
  const samples: number[] = [];
  for (let subcarrier = 0; subcarrier < 32; subcarrier += 1) {
    let amplitude = 35 + 8 * Math.sin(subcarrier * 0.31);
    if (changed) {
      amplitude *= 1 + 0.35 * Math.sin(subcarrier * 0.73);
    }
    samples.push(
      Math.round(scale * amplitude * Math.sin(subcarrier * 0.17)),
      Math.round(scale * amplitude * Math.cos(subcarrier * 0.17)),
    );
  }
  return {
    type: "csi",
    receiver: "e0:8c:fe:59:96:34",
    sequence,
    timestampUs: sequence * 50_000,
    rssi: -45,
    noiseFloor: -94,
    channel: 6,
    dropped: 0,
    samples,
  };
}

describe("room detector", () => {
  test("calibrates and detects changed channel shape", () => {
    const detector = new RoomDetector(12, 3);
    for (let sequence = 0; sequence < 12; sequence += 1) {
      detector.ingest(frame(sequence), sequence * 0.05);
    }

    assert.equal(detector.snapshot(0.6).state, "clear");
    for (let sequence = 12; sequence < 18; sequence += 1) {
      detector.ingest(frame(sequence, true), sequence * 0.05);
    }

    const snapshot = detector.snapshot(0.9);
    assert.equal(snapshot.state, "occupied");
    assert.equal(snapshot.links[0].active, true);
    assert.ok(snapshot.score > 1);
    assert.equal(detector.snapshot(4.1).state, "offline");
  });

  test("normalizes uniform gain changes", () => {
    const detector = new RoomDetector(12, 3);
    for (let sequence = 0; sequence < 12; sequence += 1) {
      detector.ingest(frame(sequence), sequence * 0.05);
    }
    for (let sequence = 12; sequence < 22; sequence += 1) {
      detector.ingest(frame(sequence, false, 1.7), sequence * 0.05);
    }

    const snapshot = detector.snapshot(1.1);
    assert.equal(snapshot.state, "clear");
    assert.ok(snapshot.score < 1);
  });

  test("reset requires fresh calibration", () => {
    const detector = new RoomDetector(10);
    for (let sequence = 0; sequence < 10; sequence += 1) {
      detector.ingest(frame(sequence), sequence * 0.05);
    }
    detector.reset();
    assert.equal(detector.snapshot(0.5).state, "offline");
    assert.equal(detector.snapshot(0.5).generation, 1);
  });
});
