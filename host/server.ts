import { isAbsolute, relative, resolve } from "node:path";

import { RoomDetector, type DetectorSnapshot } from "./detector.ts";
import type { DeviceSnapshot } from "./devices.ts";
import type { CsiFrame } from "./protocol.ts";
import { CsiSimulator } from "./simulator.ts";

const WEB_ROOT = resolve(import.meta.dir, "..", "web");

export interface Source {
  readonly rateHz: number;
  start(): void;
  stop(): void;
  snapshot(): DeviceSnapshot[];
}

export interface ApplicationSnapshot extends DetectorSnapshot {
  mode: "simulation" | "hardware";
  sampleRateHz: number;
  uptimeSeconds: number;
  devices: DeviceSnapshot[];
}

export class RadarApplication {
  readonly detector: RoomDetector;
  readonly source: Source;
  readonly mode: "simulation" | "hardware";
  private readonly startedAt = performance.now() / 1000;

  constructor(detector: RoomDetector, source: Source, mode: "simulation" | "hardware") {
    this.detector = detector;
    this.source = source;
    this.mode = mode;
  }

  ingest(frame: CsiFrame): void {
    this.detector.ingest(frame);
  }

  snapshot(): ApplicationSnapshot {
    return {
      ...this.detector.snapshot(),
      mode: this.mode,
      sampleRateHz: this.source.rateHz,
      uptimeSeconds: Number((performance.now() / 1000 - this.startedAt).toFixed(1)),
      devices: this.source.snapshot(),
    };
  }
}

function json(payload: unknown, status = 200): Response {
  return Response.json(payload, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function eventStream(application: RadarApplication, request: Request): Response {
  let eventId = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  const stream = new ReadableStream({
    start(controller) {
      const send = () => {
        const event = `id: ${eventId}\ndata: ${JSON.stringify(application.snapshot())}\n\n`;
        controller.enqueue(new TextEncoder().encode(event));
        eventId += 1;
      };
      const close = () => {
        if (timer) {
          clearInterval(timer);
          timer = null;
        }
        try {
          controller.close();
        } catch {
          // The stream may already have been canceled by the HTTP client.
        }
      };
      request.signal.addEventListener("abort", close, { once: true });
      send();
      timer = setInterval(send, 250);
    },
    cancel() {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
    },
  });
  return new Response(stream, {
    headers: {
      "Cache-Control": "no-store",
      Connection: "keep-alive",
      "Content-Type": "text/event-stream",
    },
  });
}

async function staticResponse(pathname: string): Promise<Response> {
  const relativePath = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const candidate = resolve(WEB_ROOT, relativePath);
  const pathFromRoot = relative(WEB_ROOT, candidate);
  if (pathFromRoot.startsWith("..") || isAbsolute(pathFromRoot)) {
    return new Response("Not Found", { status: 404 });
  }
  const file = Bun.file(candidate);
  if (!(await file.exists())) {
    return new Response("Not Found", { status: 404 });
  }
  return new Response(file, {
    headers: {
      "Cache-Control": candidate.endsWith(".html") ? "no-cache" : "public, max-age=300",
    },
  });
}

export function createRequestHandler(
  application: RadarApplication,
): (request: Request) => Response | Promise<Response> {
  return (request) => {
    const { pathname } = new URL(request.url);
    if (request.method === "GET") {
      if (pathname === "/api/state") {
        return json(application.snapshot());
      }
      if (pathname === "/api/health") {
        const snapshot = application.snapshot();
        const readyReceivers = snapshot.devices.filter(
          (device) => device.role === "RX" && device.ready,
        ).length;
        return json(
          { ok: readyReceivers >= 1, readyReceivers, state: snapshot.state },
          readyReceivers >= 1 ? 200 : 503,
        );
      }
      if (pathname === "/api/events") {
        return eventStream(application, request);
      }
      return staticResponse(pathname);
    }
    if (request.method === "POST" && pathname === "/api/calibrate") {
      application.detector.reset();
      return json({ ok: true }, 202);
    }
    return new Response("Not Found", { status: 404 });
  };
}

interface Arguments {
  bind: string;
  port: number;
  channel: number;
  rate: number;
  baud: number;
  ports: string[];
  simulate: boolean;
  calibrationSamples: number;
  holdSeconds: number;
  verbose: boolean;
}

const HELP = `Usage: bun run host/server.ts [options]

Options:
  --bind ADDRESS               HTTP bind address (default: 127.0.0.1)
  --port PORT                  HTTP port (default: 8080)
  --channel CHANNEL            Wi-Fi channel from 1 to 13 (default: 6)
  --rate HZ                    sample rate from 1 to 100 (default: 20)
  --baud BAUD                  serial baud rate (default: 921600)
  --ports PORT [PORT ...]      sorted serial ports; first becomes transmitter
  --simulate                   generate CSI instead of opening serial ports
  --calibration-samples COUNT  frames used for calibration (default: 80)
  --hold-seconds SECONDS       occupancy hold duration (default: 20)
  --verbose                    enable verbose request logging
  -h, --help                   show this help
`;

function numericValue(name: string, value: string, integer: boolean): number {
  const parsed = Number(value);
  if (!value.trim() || !Number.isFinite(parsed) || (integer && !Number.isInteger(parsed))) {
    throw new Error(`${name} requires a ${integer ? "whole number" : "number"}`);
  }
  return parsed;
}

export function parseArguments(argv: string[]): Arguments {
  const options: Arguments = {
    bind: "127.0.0.1",
    port: 8080,
    channel: 6,
    rate: 20,
    baud: 921_600,
    ports: [1, 2, 3, 4].map((index) => `/dev/esp32-${index}`),
    simulate: false,
    calibrationSamples: 80,
    holdSeconds: 20,
    verbose: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const [name, inlineValue] = argv[index].split("=", 2);
    const takeValue = (): string => {
      if (inlineValue !== undefined) {
        return inlineValue;
      }
      index += 1;
      if (index >= argv.length) {
        throw new Error(`${name} requires a value`);
      }
      return argv[index];
    };
    switch (name) {
      case "--bind":
        options.bind = takeValue();
        break;
      case "--port":
        options.port = numericValue(name, takeValue(), true);
        break;
      case "--channel":
        options.channel = numericValue(name, takeValue(), true);
        break;
      case "--rate":
        options.rate = numericValue(name, takeValue(), true);
        break;
      case "--baud":
        options.baud = numericValue(name, takeValue(), true);
        break;
      case "--calibration-samples":
        options.calibrationSamples = numericValue(name, takeValue(), true);
        break;
      case "--hold-seconds":
        options.holdSeconds = numericValue(name, takeValue(), false);
        break;
      case "--ports": {
        const ports = inlineValue === undefined ? [] : [inlineValue];
        while (index + 1 < argv.length && !argv[index + 1].startsWith("-")) {
          ports.push(argv[++index]);
        }
        if (ports.length === 0 || ports.some((port) => !port)) {
          throw new Error("--ports requires at least one port");
        }
        options.ports = ports;
        break;
      }
      case "--simulate":
        options.simulate = true;
        break;
      case "--verbose":
        options.verbose = true;
        break;
      case "-h":
      case "--help":
        console.info(HELP);
        process.exit(0);
      default:
        throw new Error(`unknown option: ${name}`);
    }
  }

  if (options.port < 0 || options.port > 65_535) {
    throw new Error("--port must be between 0 and 65535");
  }
  if (options.channel < 1 || options.channel > 13) {
    throw new Error("--channel must be between 1 and 13");
  }
  if (options.rate < 1 || options.rate > 100) {
    throw new Error("--rate must be between 1 and 100");
  }
  return options;
}

export async function main(): Promise<void> {
  let options: Arguments;
  try {
    options = parseArguments(Bun.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    console.error("Use --help for usage.");
    process.exit(2);
  }

  const detector = new RoomDetector(options.calibrationSamples, options.holdSeconds);
  let source: Source;
  if (options.simulate) {
    source = new CsiSimulator((frame) => detector.ingest(frame), options.rate);
  } else {
    const { SerialFleet } = await import("./devices.ts");
    source = new SerialFleet(
      options.ports,
      (frame) => detector.ingest(frame),
      options.channel,
      options.rate,
      options.baud,
    );
  }
  const application = new RadarApplication(
    detector,
    source,
    options.simulate ? "simulation" : "hardware",
  );
  const handler = createRequestHandler(application);
  const server = Bun.serve({
    hostname: options.bind,
    port: options.port,
    fetch(request) {
      if (options.verbose && new URL(request.url).pathname !== "/api/events") {
        console.info(`${request.method} ${new URL(request.url).pathname}`);
      }
      return handler(request);
    },
  });
  source.start();
  console.info(`serving ${application.mode} mode on ${server.url}`);

  let shutdownStarted = false;
  const shutdown = () => {
    if (shutdownStarted) {
      return;
    }
    shutdownStarted = true;
    source.stop();
    server.stop(true);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
