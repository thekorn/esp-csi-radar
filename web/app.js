const elements = {
  body: document.body,
  connectionDot: document.querySelector("#connection-dot"),
  connectionLabel: document.querySelector("#connection-label"),
  modeLabel: document.querySelector("#mode-label"),
  stateKicker: document.querySelector("#state-kicker"),
  stateTitle: document.querySelector("#state-title"),
  stateDescription: document.querySelector("#state-description"),
  activityScore: document.querySelector("#activity-score"),
  linkCount: document.querySelector("#link-count"),
  channelLabel: document.querySelector("#channel-label"),
  gauge: document.querySelector("#radar-gauge"),
  gaugeValue: document.querySelector("#gauge-value"),
  roomStatus: document.querySelector("#room-status"),
  calibrationOverlay: document.querySelector("#calibration-overlay"),
  calibrationPercent: document.querySelector("#calibration-percent"),
  calibrationProgress: document.querySelector("#calibration-progress"),
  linkCards: document.querySelector("#link-cards"),
  sampleRate: document.querySelector(".sample-rate"),
  deviceList: document.querySelector("#device-list"),
  uptimeLabel: document.querySelector("#uptime-label"),
  dialog: document.querySelector("#calibration-dialog"),
  openCalibration: document.querySelector("#open-calibration"),
  startCalibration: document.querySelector("#start-calibration"),
};

const stateCopy = {
  offline: {
    kicker: "Waiting for sensors",
    title: "Radar offline",
    description: "Connect the ESP32 array to begin room sensing.",
  },
  calibrating: {
    kicker: "Baseline in progress",
    title: "Learning the room",
    description: "Measuring the empty-room radio fingerprint. Keep the sensing area clear and still.",
  },
  clear: {
    kicker: "No significant change",
    title: "Room is clear",
    description: "All sensing links are stable against the calibrated empty-room baseline.",
  },
  occupied: {
    kicker: "Channel change detected",
    title: "Presence detected",
    description: "One or more sensing links show a sustained change in the room's radio field.",
  },
};

const escapeHtml = (value) => String(value ?? "—")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#039;");

const formatUptime = (seconds) => {
  const total = Math.max(0, Math.round(seconds || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainder = total % 60;
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m ${remainder}s`;
};

function renderSparkline(canvas, history, active) {
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(10, canvas.clientWidth);
  const height = Math.max(10, canvas.clientHeight);
  if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  const context = canvas.getContext("2d");
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  context.clearRect(0, 0, width, height);

  const thresholdY = height - (1 / 4) * height;
  context.strokeStyle = "rgba(255, 196, 91, .20)";
  context.setLineDash([3, 4]);
  context.beginPath();
  context.moveTo(0, thresholdY);
  context.lineTo(width, thresholdY);
  context.stroke();
  context.setLineDash([]);

  if (!history.length) return;
  const color = active ? "255, 196, 91" : "99, 215, 231";
  const gradient = context.createLinearGradient(0, 0, 0, height);
  gradient.addColorStop(0, `rgba(${color}, .20)`);
  gradient.addColorStop(1, `rgba(${color}, 0)`);
  const points = history.map((value, index) => ({
    x: history.length === 1 ? width : index * width / (history.length - 1),
    y: height - Math.min(4, Math.max(0, value)) / 4 * height,
  }));
  context.beginPath();
  points.forEach((point, index) => index ? context.lineTo(point.x, point.y) : context.moveTo(point.x, point.y));
  context.lineTo(width, height);
  context.lineTo(0, height);
  context.closePath();
  context.fillStyle = gradient;
  context.fill();
  context.beginPath();
  points.forEach((point, index) => index ? context.lineTo(point.x, point.y) : context.moveTo(point.x, point.y));
  context.strokeStyle = `rgb(${color})`;
  context.lineWidth = 1.5;
  context.stroke();
}

function renderLinks(links) {
  if (!links.length) {
    elements.linkCards.innerHTML = '<div class="empty-links">Waiting for CSI frames…</div>';
  } else {
    elements.linkCards.innerHTML = links.map((link, index) => `
      <article class="link-card ${link.active ? "active" : ""}" data-receiver="${escapeHtml(link.receiver)}">
        <div class="link-card-head">
          <div class="link-identity">
            <span class="link-number">L${index + 1}</span>
            <span><strong>Receiver ${index + 1}</strong><small>${escapeHtml(link.receiver)}</small></span>
          </div>
          <span class="link-score"><small>SCORE</small> ${Number(link.score).toFixed(2)}</span>
        </div>
        <canvas class="sparkline" aria-label="Receiver ${index + 1} activity history"></canvas>
        <div class="link-stats">
          <span>RSSI <b>${link.rssi} dBm</b></span>
          <span>Frames <b>${Number(link.frames).toLocaleString()}</b></span>
          <span>Lost <b>${Number(link.dropped).toLocaleString()}</b></span>
        </div>
      </article>
    `).join("");
    elements.linkCards.querySelectorAll(".link-card").forEach((card, index) => {
      renderSparkline(card.querySelector("canvas"), links[index].history, links[index].active);
    });
  }

  document.querySelectorAll(".radio-link").forEach((linkElement, index) => {
    const link = links[index];
    linkElement.classList.toggle("hot", Boolean(link?.active));
    linkElement.style.opacity = link ? String(Math.max(.35, Math.min(1, .35 + link.score * .3))) : ".15";
  });
}

function renderDevices(devices) {
  elements.deviceList.innerHTML = devices.map((device, index) => `
    <div class="device ${device.ready ? "ready" : ""}" title="${escapeHtml(device.error || "Device ready")}">
      <span class="device-indicator"></span>
      <span>
        <strong>ESP32 · ${String(index + 1).padStart(2, "0")}</strong>
        <small>${escapeHtml(device.mac || device.port)}</small>
      </span>
      <span class="device-role">${escapeHtml(device.role)}</span>
    </div>
  `).join("");
}

function render(state) {
  const current = stateCopy[state.state] ? state.state : "offline";
  const copy = stateCopy[current];
  elements.body.dataset.state = current;
  elements.stateKicker.textContent = copy.kicker;
  elements.stateTitle.textContent = copy.title;
  elements.stateDescription.textContent = copy.description;
  elements.roomStatus.textContent = current;
  elements.modeLabel.textContent = state.mode === "simulation" ? "Simulation" : "Hardware";

  const links = state.links || [];
  const liveLinks = links.filter((link) => Number(link.lastSeenSeconds) <= 2);
  const normalizedScore = Math.min(1, Number(state.score || 0) / 2);
  elements.activityScore.textContent = Number(state.score || 0).toFixed(2);
  elements.linkCount.textContent = `${liveLinks.length} / 3`;
  elements.channelLabel.textContent = liveLinks.length ? `CH ${liveLinks[0].channel}` : "—";
  elements.gauge.style.setProperty("--score", normalizedScore);
  elements.gaugeValue.textContent = String(Math.round(normalizedScore * 100));
  elements.sampleRate.textContent = `${Number(state.sampleRateHz || 0)} Hz`;
  elements.uptimeLabel.textContent = `Uptime ${formatUptime(state.uptimeSeconds)}`;

  const calibrating = current === "calibrating";
  const calibration = Math.max(0, Math.min(1, Number(state.calibration || 0)));
  elements.calibrationOverlay.hidden = !calibrating;
  elements.calibrationPercent.textContent = `${Math.round(calibration * 100)}%`;
  elements.calibrationProgress.style.width = `${calibration * 100}%`;

  renderLinks(links);
  renderDevices(state.devices || []);
}

async function loadInitialState() {
  try {
    const response = await fetch("api/state", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    render(await response.json());
  } catch (error) {
    elements.connectionLabel.textContent = "Server unavailable";
  }
}

function connectEvents() {
  const events = new EventSource("api/events");
  events.onopen = () => {
    elements.connectionDot.classList.add("connected");
    elements.connectionLabel.textContent = "Live stream";
  };
  events.onmessage = (event) => render(JSON.parse(event.data));
  events.onerror = () => {
    elements.connectionDot.classList.remove("connected");
    elements.connectionLabel.textContent = "Reconnecting";
  };
}

elements.openCalibration.addEventListener("click", () => elements.dialog.showModal());
elements.startCalibration.addEventListener("click", async (event) => {
  event.preventDefault();
  elements.startCalibration.disabled = true;
  try {
    const response = await fetch("api/calibrate", { method: "POST" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    elements.dialog.close();
  } finally {
    elements.startCalibration.disabled = false;
  }
});

loadInitialState();
connectEvents();
