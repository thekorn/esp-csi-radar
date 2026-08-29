import assert from "node:assert/strict";
import { describe, test } from "node:test";

import { ProtocolError, parseLine } from "../protocol.ts";

describe("serial protocol", () => {
  test("ignores ESP-IDF logs", () => {
    assert.equal(parseLine("I (328) wifi:mode : sta"), null);
  });

  test("parses hello", () => {
    assert.deepEqual(parseLine("RADAR,HELLO,F42DC96BF200,esp32\n"), {
      type: "hello",
      mac: "f4:2d:c9:6b:f2:00",
      chip: "esp32",
    });
  });

  test("parses role readiness with a stable identity", () => {
    assert.deepEqual(parseLine("RADAR,READY,TX,F42DC96BF200,6,20\n"), {
      type: "ready",
      role: "TX",
      mac: "f4:2d:c9:6b:f2:00",
      channel: 6,
      detail: "20",
    });
  });

  test("parses signed CSI", () => {
    const message = parseLine("RADAR,CSI,e0:8c:fe:59:96:34,7,1234,-47,-94,6,2,4,00ff7f80");
    assert.equal(message?.type, "csi");
    if (message?.type !== "csi") {
      throw new Error("expected a CSI message");
    }
    assert.deepEqual(message.samples, [0, -1, 127, -128]);
    assert.equal(message.dropped, 2);
  });

  test("rejects truncated payload", () => {
    assert.throws(
      () => parseLine("RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,8,00ff"),
      new ProtocolError("CSI payload length is 2, expected 8"),
    );
  });
});
