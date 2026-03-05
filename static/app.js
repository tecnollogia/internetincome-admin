const fields = [
  "DEVICE_NAME", "USE_PROXIES", "ENABLE_LOGS", "AUTO_HEAL", "ENABLE_HOST_GUARD", "AUTO_REBOOT_ON_CRITICAL", "CHECK_PROXY_BEFORE_START",
  "EARNAPP_IMAGE", "TUN_IMAGE", "TUN_LOG_LEVEL", "EARNAPP_CPUS", "EARNAPP_MEMORY",
  "TUN_CPUS", "TUN_MEMORY", "PIDS_LIMIT", "START_DELAY_SEC", "DELAY_BETWEEN_TUN_AND_EARNAPP_SEC", "MAX_STACKS",
  "AUTO_RESTART_COOLDOWN_SEC", "HOST_ACTION_COOLDOWN_SEC", "CRITICAL_STREAK_THRESHOLD", "CPU_CRITICAL_PERCENT", "MEM_CRITICAL_PERCENT",
  "DISK_CRITICAL_PERCENT", "LOAD_CRITICAL_PER_CPU", "MONITOR_INTERVAL_SEC", "PROXY_CHECK_INTERVAL_SEC",
  "EARNAPP_PLATFORM", "TUN_PLATFORM"
];

const $ = (id) => document.getElementById(id);

function boolString(v) { return v ? "true" : "false"; }

function setConsole(message, isError = false) {
  const box = $("actionResult");
  box.style.color = isError ? "#ffd0d0" : "#d4f5c8";
  box.textContent = message || "";
}

function renderRows(targetId, rows, emptyText) {
  const box = $(targetId);
  box.innerHTML = "";
  if (!rows || rows.length === 0) {
    const el = document.createElement("div");
    el.className = "row";
    el.textContent = emptyText;
    box.appendChild(el);
    return;
  }
  rows.forEach((html) => {
    const el = document.createElement("div");
    el.className = "row";
    el.innerHTML = html;
    box.appendChild(el);
  });
}

function setBusy(busy) {
  const badge = $("busyBadge");
  badge.classList.toggle("busy", busy);
  badge.textContent = busy ? "Running..." : "Idle";
}

function collectConfig() {
  const config = {};
  fields.forEach((key) => {
    const el = $(key);
    if (!el) return;
    const val = el.value;
    config[key] = (val === "true" || val === "false") ? val === "true" : val;
  });
  return config;
}

function applyConfig(config) {
  fields.forEach((key) => {
    const el = $(key);
    if (!el || !(key in config)) return;
    el.value = typeof config[key] === "boolean" ? boolString(config[key]) : config[key];
  });
}

function secToHuman(sec) {
  sec = Number(sec || 0);
  if (sec <= 0) return "0s";
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const parts = [];
  if (d) parts.push(`${d}d`);
  if (h) parts.push(`${h}h`);
  if (m) parts.push(`${m}m`);
  if (s && parts.length < 2) parts.push(`${s}s`);
  return parts.join(" ");
}

function renderProxyTable(items) {
  if (!items || items.length === 0) {
    $("proxyHealth").innerHTML = '<div class="row">Nessun proxy configurato.</div>';
    return;
  }
  const rows = items.map((p) => `
    <tr>
      <td>#${p.index}</td>
      <td><code>${p.host}:${p.port}</code></td>
      <td class="${p.online ? "status-ok" : "status-off"}">${p.online ? "online" : "offline"}</td>
      <td>${p.fail_rate_percent}%</td>
      <td>${secToHuman(p.offline_for_sec)}</td>
      <td>${secToHuman(p.total_offline_sec)}</td>
      <td>${p.last_seen_online || "-"}</td>
    </tr>
  `).join("");

  $("proxyHealth").innerHTML = `
    <table class="table">
      <thead><tr><th>ID</th><th>Proxy</th><th>Status</th><th>Fail %</th><th>Offline Now</th><th>Total Offline</th><th>Last Online</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `;
}

function renderUsageTable(items) {
  if (!items || items.length === 0) {
    $("usageTable").innerHTML = '<div class="row">Nessun dato usage disponibile.</div>';
    return;
  }
  const rows = items.map((u) => `
    <tr>
      <td><code>${u.name}</code></td>
      <td>${u.cpu}</td>
      <td>${u.mem_usage}</td>
      <td>${u.mem_percent}</td>
    </tr>
  `).join("");

  $("usageTable").innerHTML = `
    <table class="table">
      <thead><tr><th>Container</th><th>CPU</th><th>Mem Usage</th><th>Mem %</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `;
}

function renderEarnappMapTable(items) {
  if (!items || items.length === 0) {
    $("earnappMapTable").innerHTML = '<div class="row">Nessuna associazione disponibile.</div>';
    return;
  }
  const rows = items.map((r) => `
    <tr>
      <td>#${r.index}</td>
      <td><code>${r.earnapp_container || "-"}</code><br><span class="${(r.earnapp_status || "").toLowerCase().startsWith("up") ? "status-ok" : "status-off"}">${r.earnapp_status || "-"}</span></td>
      <td><code>${r.tun_container || "-"}</code><br><span class="${(r.tun_status || "").toLowerCase().startsWith("up") ? "status-ok" : "status-off"}">${r.tun_status || "-"}</span></td>
      <td><code>${r.proxy || "-"}</code></td>
      <td>${r.earnapp_link ? `<a href="${r.earnapp_link}" target="_blank" rel="noopener noreferrer">${r.earnapp_link}</a>` : "-"}</td>
    </tr>
  `).join("");

  $("earnappMapTable").innerHTML = `
    <table class="table">
      <thead><tr><th>ID</th><th>EarnApp Container</th><th>TUN Container</th><th>Proxy</th><th>EarnApp Link</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `;
}

async function fetchState() {
  const res = await fetch("/api/state");
  if (!res.ok) throw new Error("Errore caricamento stato");
  const state = await res.json();

  applyConfig(state.config || {});
  setBusy(!!state.busy);

  const summary = state.summary || {};
  $("onlineProxies").textContent = String(summary.online_proxies || 0);
  $("offlineProxies").textContent = String(summary.offline_proxies || 0);
  $("upCount").textContent = String(summary.running_containers || 0);
  $("downCount").textContent = String((summary.stopped_containers || 0) + (summary.missing_containers || 0));
  $("knownCount").textContent = String(state.known_container_count || 0);

  const host = state.monitor?.host || {};
  $("hostCpu").textContent = `${host.cpu_percent || 0}%`;
  $("hostMem").textContent = `${host.mem_percent || 0}%`;
  $("hostDisk").textContent = `${host.disk_percent || 0}%`;
  $("hostLoad").textContent = `${host.load1 || 0}`;
  $("hostUptime").textContent = host.uptime || "-";
  const hg = state.monitor?.host_guard || {};
  const guardLabel = hg.critical ? `critical L${hg.guard_level || 0}` : "ok";
  $("hostGuard").textContent = guardLabel;

  $("proxiesBox").value = (state.proxies || []).join("\n");
  renderProxyTable(state.monitor?.proxies || []);
  renderUsageTable(state.monitor?.usage || []);
  renderEarnappMapTable(state.earnapp_stacks || []);

  const links = (state.links || []).map((link) => `<a href="${link}" target="_blank" rel="noopener noreferrer">${link}</a>`);
  renderRows("linksList", links, "Nessun link disponibile.");

  const events = (state.monitor?.events || []).map((e) => `<code>${String(e).replace(/</g, "&lt;")}</code>`);
  renderRows("eventsList", events, "Nessun evento.");

  const cmds = (state.recent_commands || []).map((cmd) => {
    const head = `${cmd.ok ? "OK" : "ERR"} | ${cmd.command} | rc=${cmd.returncode}`;
    const body = (cmd.stdout || cmd.stderr || "(no output)").replace(/</g, "&lt;");
    return `<b>${head}</b><br><code>${body}</code>`;
  });
  renderRows("cmdList", cmds, "Nessun comando eseguito da UI.");
}

async function postJson(url, payload) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {}),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || data.stderr || `HTTP ${res.status}`);
  return data;
}

async function runAction(action) {
  setConsole(`Esecuzione: ${action}...`);
  try {
    const out = await postJson(`/api/action/${action}`, {});
    const text = [out.command, `rc=${out.returncode}`, out.stdout || out.stderr || ""].join("\n\n");
    setConsole(text, !out.ok);
  } catch (err) {
    setConsole(String(err.message || err), true);
  }
  await fetchState();
}

async function saveConfig() {
  try {
    await postJson("/api/config", { config: collectConfig() });
    setConsole("Configurazione salvata.");
  } catch (err) {
    setConsole(`Errore config: ${err.message || err}`, true);
  }
  await fetchState();
}

async function saveProxies() {
  const text = $("proxiesBox").value || "";
  try {
    const out = await postJson("/api/proxies", { text });
    setConsole(`Proxies salvati: ${out.count}`);
  } catch (err) {
    setConsole(`Errore proxies: ${err.message || err}`, true);
  }
  await fetchState();
}

async function forceCheckProxies() {
  try {
    const out = await postJson("/api/proxies/check", {});
    setConsole(`Proxy check completato. Online: ${out.online}, Offline: ${out.offline}`);
  } catch (err) {
    setConsole(`Errore check proxy: ${err.message || err}`, true);
  }
  await fetchState();
}

function bindUI() {
  $("refreshBtn").addEventListener("click", fetchState);
  $("saveConfigBtn").addEventListener("click", saveConfig);
  $("saveProxiesBtn").addEventListener("click", saveProxies);
  $("checkProxiesBtn").addEventListener("click", forceCheckProxies);
  $("startBtn").addEventListener("click", () => runAction("start"));
  $("stopBtn").addEventListener("click", () => runAction("stop"));
  $("cleanupBtn").addEventListener("click", () => runAction("cleanup"));
}

bindUI();
fetchState();
setInterval(fetchState, 10000);
