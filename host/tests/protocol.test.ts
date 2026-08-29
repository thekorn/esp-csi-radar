import { describe, expect, test } from "bun:test";

import { ProtocolError, parseLine } from "../protocol.ts";

describe("serial protocol", () => {
  test("ignores ESP-IDF logs", () => {
    expect(parseLine("I (328) wifi:mode : sta")).toBeNull();
  });

  test("parses hello", () => {
    expect(parseLine("RADAR,HELLO,F42DC96BF200,esp32\n")).toEqual({
      type: "hello",
      mac: "f4:2d:c9:6b:f2:00",
      chip: "esp32",
    });
  });

  test("parses signed CSI", () => {
    const message = parseLine("RADAR,CSI,e0:8c:fe:59:96:34,7,1234,-47,-94,6,2,4,00ff7f80");
    expect(message?.type).toBe("csi");
    if (message?.type !== "csi") {
      throw new Error("expected a CSI message");
    }
    expect(message.samples).toEqual([0, -1, 127, -128]);
    expect(message.dropped).toBe(2);
  });

  test("rejects truncated payload", () => {
    expect(() => parseLine("RADAR,CSI,e08cfe599634,7,1234,-47,-94,6,0,8,00ff")).toThrow(
      new ProtocolError("CSI payload length is 2, expected 8"),
    );
  });
});
