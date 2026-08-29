import assert from "node:assert/strict";
import { describe, test } from "node:test";

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
    assert.equal(stateResponse.status, 200);
    assert.equal(stateResponse.headers.get("cache-control"), "no-store");
    const state = await stateResponse.json();
    assert.deepEqual(
      { state: state.state, mode: state.mode, sampleRateHz: state.sampleRateHz },
      {
        state: "offline",
        mode: "simulation",
        sampleRateHz: 20,
      },
    );

    const healthResponse = await handler(new Request("http://radar.test/api/health"));
    assert.equal(healthResponse.status, 200);
    assert.deepEqual(await healthResponse.json(), {
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
    assert.equal(calibrationResponse.status, 202);
    assert.equal(detector.generation, 1);

    const dashboardResponse = await handler(new Request("http://radar.test/"));
    assert.equal(dashboardResponse.status, 200);
    assert.ok(dashboardResponse.headers.get("content-type")?.startsWith("text/html"));
    assert.ok((await dashboardResponse.text()).includes("<title>Room Radar · ESP CSI</title>"));
  });

  test("parses the compatible command-line options", () => {
    const options = parseArguments([
      "--simulate",
      "--bind",
      "0.0.0.0",
      "--port=9000",
      "--ports=/dev/esp32-2",
      "/dev/esp32-1",
    ]);
    assert.equal(options.mode, "simulation");
    assert.equal(options.bind, "0.0.0.0");
    assert.equal(options.port, 9000);
    assert.deepEqual(options.ports, ["/dev/esp32-2", "/dev/esp32-1"]);
    assert.throws(() => parseArguments(["--port="]), /--port requires a whole number/);
  });

  test("selects serial and WebSocket ingestion modes", () => {
    const serialOptions = parseArguments([], {});
    assert.equal(serialOptions.mode, "serial");
    assert.equal(serialOptions.bind, "127.0.0.1");
    assert.equal(serialOptions.port, 8080);

    const socketOptions = parseArguments(["--socket"], { ESP_SERVER_PORT: "9080" });
    assert.equal(socketOptions.mode, "socket");
    assert.equal(socketOptions.bind, "0.0.0.0");
    assert.equal(socketOptions.port, 9080);
    assert.throws(
      () => parseArguments([], { ESP_SERVER_PORT: "0" }),
      /--port must be between 1 and 65535/,
    );
    assert.throws(() => parseArguments(["--serial", "--socket"], {}), /mutually exclusive/);
  });
});
