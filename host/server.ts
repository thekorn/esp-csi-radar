import { readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { extname, isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Readable } from "node:stream";
import { WebSocketServer } from "ws";

import { RoomDetector, type DetectorSnapshot } from "./detector.ts";
import type { DeviceSnapshot, SocketFleet } from "./devices.ts";
import type { CsiFrame } from "./protocol.ts";
import { CsiSimulator } from "./simulator.ts";

const WEB_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)), "web");

const CONTENT_TYPES: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
};

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
  let file: Uint8Array;
  try {
    file = await readFile(candidate);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return new Response("Not Found", { status: 404 });
    }
    throw error;
  }
  return new Response(new Uint8Array(file).buffer, {
    headers: {
      "Cache-Control": candidate.endsWith(".html") ? "no-cache" : "public, max-age=300",
      "Content-Type": CONTENT_TYPES[extname(candidate)] ?? "application/octet-stream",
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

async function startHttpServer(
  hostname: string,
  port: number,
  fetch: (request: Request) => Response | Promise<Response>,
): Promise<Server> {
  const server = createServer(async (incoming, outgoing) => {
    const abort = new AbortController();
    outgoing.once("close", () => abort.abort());
    try {
      const headers = new Headers();
      for (let index = 0; index < incoming.rawHeaders.length; index += 2) {
        headers.append(incoming.rawHeaders[index], incoming.rawHeaders[index + 1]);
      }
      const body =
        incoming.method === "GET" || incoming.method === "HEAD"
          ? undefined
          : Readable.toWeb(incoming);
      const request = new Request(
        `http://${incoming.headers.host ?? `${hostname}:${port}`}${incoming.url}`,
        {
          method: incoming.method,
          headers,
          body,
          duplex: body ? "half" : undefined,
          signal: abort.signal,
        } as RequestInit,
      );
      const response = await fetch(request);
      outgoing.writeHead(response.status, Object.fromEntries(response.headers));
      if (incoming.method === "HEAD" || !response.body) {
        outgoing.end();
      } else {
        Readable.fromWeb(response.body as unknown as Parameters<typeof Readable.fromWeb>[0]).pipe(
          outgoing,
        );
      }
    } catch (error) {
      console.error(error);
      if (!outgoing.headersSent) {
        outgoing.writeHead(500);
      }
      outgoing.end("Internal Server Error");
    }
  });
  await new Promise<void>((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(port, hostname, () => {
      server.off("error", reject);
      resolveListen();
    });
  });
  return server;
}

interface Arguments {
  bind: string;
  port: number;
  rate: number;
  baud: number;
  ports: string[];
  mode: "serial" | "socket" | "simulation";
  calibrationSamples: number;
  holdSeconds: number;
  verbose: boolean;
}

const HELP = `Usage: node host/server.ts [options]

Options:
  --bind ADDRESS               HTTP bind address (default: 127.0.0.1)
  --port PORT                  HTTP port (default: ESP_SERVER_PORT or 8080)
  --rate HZ                    sample rate from 1 to 100 (default: 20)
  --baud BAUD                  serial baud rate (default: 921600)
  --ports PORT [PORT ...]      serial ports in esp32-1 through esp32-4 order
  --serial                     ingest device records over USB serial (default)
  --socket                     ingest device records at WebSocket path /device
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

export function parseArguments(
  argv: string[],
  environment: Record<string, string | undefined> = process.env,
): Arguments {
  const environmentPort = environment.ESP_SERVER_PORT;
  const options: Arguments = {
    bind: "127.0.0.1",
    port: environmentPort ? numericValue("ESP_SERVER_PORT", environmentPort, true) : 8080,
    rate: 20,
    baud: 921_600,
    ports: [1, 2, 3, 4].map((index) => `/dev/esp32-${index}`),
    mode: "serial",
    calibrationSamples: 80,
    holdSeconds: 20,
    verbose: false,
  };
  let bindWasSet = false;
  let modeWasSet = false;

  const selectMode = (mode: Arguments["mode"]): void => {
    if (modeWasSet && options.mode !== mode) {
      throw new Error("--serial, --socket, and --simulate are mutually exclusive");
    }
    options.mode = mode;
    modeWasSet = true;
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
        bindWasSet = true;
        break;
      case "--port":
        options.port = numericValue(name, takeValue(), true);
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
      case "--serial":
        selectMode("serial");
        break;
      case "--socket":
        selectMode("socket");
        break;
      case "--simulate":
        selectMode("simulation");
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

  if (options.port < 1 || options.port > 65_535) {
    throw new Error("--port must be between 1 and 65535");
  }
  if (options.rate < 1 || options.rate > 100) {
    throw new Error("--rate must be between 1 and 100");
  }
  if (options.mode === "socket" && !bindWasSet) {
    options.bind = "0.0.0.0";
  }
  return options;
}

export async function main(): Promise<void> {
  let options: Arguments;
  try {
    options = parseArguments(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    console.error("Use --help for usage.");
    process.exit(2);
  }

  const detector = new RoomDetector(options.calibrationSamples, options.holdSeconds);
  let source: Source;
  let socketSource: SocketFleet | null = null;
  if (options.mode === "simulation") {
    source = new CsiSimulator((frame) => detector.ingest(frame), options.rate);
  } else if (options.mode === "serial") {
    const { SerialFleet } = await import("./devices.ts");
    source = new SerialFleet(
      options.ports,
      (frame) => detector.ingest(frame),
      options.rate,
      options.baud,
    );
  } else {
    const { SocketFleet: SocketFleetClass } = await import("./devices.ts");
    socketSource = new SocketFleetClass((frame) => detector.ingest(frame), options.rate);
    source = socketSource;
  }
  const application = new RadarApplication(
    detector,
    source,
    options.mode === "simulation" ? "simulation" : "hardware",
  );
  const handler = createRequestHandler(application);
  const server = await startHttpServer(options.bind, options.port, (request) => {
    if (options.verbose && new URL(request.url).pathname !== "/api/events") {
      console.info(`${request.method} ${new URL(request.url).pathname}`);
    }
    return handler(request);
  });
  let websocketServer: WebSocketServer | null = null;
  if (socketSource) {
    const fleet = socketSource;
    const upgradeServer = new WebSocketServer({
      noServer: true,
      maxPayload: 1200,
      perMessageDeflate: false,
    });
    websocketServer = upgradeServer;
    server.on("upgrade", (request, socket, head) => {
      const pathname = new URL(
        request.url ?? "/",
        `http://${request.headers.host ?? `${options.bind}:${options.port}`}`,
      ).pathname;
      if (pathname !== "/device") {
        socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      upgradeServer.handleUpgrade(request, socket, head, (websocket) => {
        fleet.accept(websocket);
      });
    });
  }
  source.start();
  console.info(
    `serving ${application.mode} mode via ${options.mode} on http://${options.bind}:${options.port}/`,
  );

  let shutdownStarted = false;
  const shutdown = () => {
    if (shutdownStarted) {
      return;
    }
    shutdownStarted = true;
    source.stop();
    websocketServer?.clients.forEach((socket) => socket.close(1001, "server stopping"));
    websocketServer?.close();
    server.close();
    server.closeAllConnections();
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
