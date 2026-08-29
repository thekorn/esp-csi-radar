import { describe, expect, test } from "bun:test";
import type { WebSocket } from "ws";

import { SerialFleet, SocketFleet } from "../devices.ts";
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

  test("associates WebSocket records with a known device", () => {
    const frames: CsiFrame[] = [];
    const fleet = new SocketFleet((frame) => frames.push(frame));
    const closed: Array<[number | undefined, string | undefined]> = [];
    const socket = {
      close(code?: number, reason?: string) {
        closed.push([code, reason]);
      },
    } as unknown as WebSocket;
    fleet.start();

    fleet.handleSocketMessage(socket, "RADAR,HELLO,e08cfe599634,esp32\n");
    fleet.handleSocketMessage(socket, "RADAR,READY,RX,e08cfe599634,6,f42dc96bf200\n");
    fleet.handleSocketMessage(socket, "RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,4,00ff7f80\n");

    expect(closed).toEqual([]);
    expect(fleet.snapshot()[1]).toMatchObject({ connected: true, ready: true, chip: "esp32" });
    expect(frames).toHaveLength(1);

    fleet.closeSocket(socket);
    expect(fleet.snapshot()[1]).toMatchObject({ connected: false, ready: false });
  });

  test("rejects an unknown WebSocket device", () => {
    const fleet = new SocketFleet(() => {});
    const closed: number[] = [];
    const socket = {
      close(code?: number) {
        if (code) closed.push(code);
      },
    } as unknown as WebSocket;
    fleet.start();

    fleet.handleSocketMessage(socket, "RADAR,HELLO,001122334455,esp32\n");

    expect(closed).toEqual([1008]);
  });
});
