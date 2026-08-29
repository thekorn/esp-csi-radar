import { describe, expect, test } from "bun:test";

import { SerialFleet } from "../devices.ts";
import type { CsiFrame } from "../protocol.ts";

describe("serial fleet", () => {
  test("valid CSI confirms receiver readiness and recovers an error", () => {
    const frames: CsiFrame[] = [];
    const fleet = new SerialFleet(["/dev/esp32-1", "/dev/esp32-2"], (frame) => frames.push(frame));
    const receiver = fleet.connections[1];
    receiver.status.error = "transient malformed line";
    receiver.status.malformed = 1;
    const frame: CsiFrame = {
      type: "csi",
      receiver: "e0:8c:fe:59:96:34",
      sequence: 1,
      timestampUs: 50_000,
      rssi: -45,
      noiseFloor: -96,
      channel: 6,
      dropped: 0,
      samples: Array(8).fill([1, 2]).flat(),
    };

    fleet.handleMessage(receiver, frame);

    expect(receiver.status.ready).toBe(true);
    expect(receiver.status.error).toBeNull();
    expect(receiver.status.malformed).toBe(1);
    expect(frames).toEqual([frame]);
  });
});
