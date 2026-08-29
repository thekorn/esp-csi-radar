import { describe, expect, test } from "bun:test";

import { RoomDetector } from "../detector.ts";
import { RadarApplication, createRequestHandler, parseArguments, type Source } from "../server.ts";

const source: Source = {
  rateHz: 20,
  start() {},
  stop() {},
  snapshot() {
    return [
      {
        port: "sim://rx-1",
        role: "RX",
        connected: true,
        ready: true,
        mac: "e0:8c:fe:59:96:34",
        chip: "esp32-simulated",
        error: null,
        malformed: 0,
      },
    ];
  },
};

describe("HTTP server", () => {
  test("serves health and state with the existing API schema", async () => {
    const application = new RadarApplication(new RoomDetector(), source, "simulation");
    const handler = createRequestHandler(application);

    const stateResponse = await handler(new Request("http://radar.test/api/state"));
    expect(stateResponse.status).toBe(200);
    expect(stateResponse.headers.get("cache-control")).toBe("no-store");
    expect(await stateResponse.json()).toMatchObject({
      state: "offline",
      mode: "simulation",
      sampleRateHz: 20,
    });

    const healthResponse = await handler(new Request("http://radar.test/api/health"));
    expect(healthResponse.status).toBe(200);
    expect(await healthResponse.json()).toEqual({
      ok: true,
      readyReceivers: 1,
      state: "offline",
    });
  });

  test("resets calibration and serves the dashboard", async () => {
    const detector = new RoomDetector();
    const handler = createRequestHandler(new RadarApplication(detector, source, "simulation"));

    const calibrationResponse = await handler(
      new Request("http://radar.test/api/calibrate", { method: "POST" }),
    );
    expect(calibrationResponse.status).toBe(202);
    expect(detector.generation).toBe(1);

    const dashboardResponse = await handler(new Request("http://radar.test/"));
    expect(dashboardResponse.status).toBe(200);
    expect(dashboardResponse.headers.get("content-type")).toStartWith("text/html");
    expect(await dashboardResponse.text()).toContain("<title>Room Radar · ESP CSI</title>");
  });

  test("parses the compatible command-line options", () => {
    expect(
      parseArguments([
        "--simulate",
        "--bind",
        "0.0.0.0",
        "--port=9000",
        "--ports=/dev/esp32-2",
        "/dev/esp32-1",
      ]),
    ).toMatchObject({
      simulate: true,
      bind: "0.0.0.0",
      port: 9000,
      ports: ["/dev/esp32-2", "/dev/esp32-1"],
    });
    expect(() => parseArguments(["--port="])).toThrow("--port requires a whole number");
  });
});
