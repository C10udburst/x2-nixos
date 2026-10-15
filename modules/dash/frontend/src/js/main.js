// Dashboard entry point: polls /api/status and drives every view.

import { fetchStatus, stopWorkloads, switchModel } from "./api.js";
import { METRICS, initCharts, pushMetric, setMetricSub } from "./charts.js";
import { clearNotify, initNotify, notify } from "./notify.js";
import { clearPlaygroundTargetPick, initPlayground, setPlaygroundTarget } from "./playground.js";
import { initModels, renderModels } from "./models.js";
import { initServices, renderServices } from "./services.js";
import { inferenceTarget, POLL_INTERVAL_MS, state } from "./state.js";
import { readTelemetry } from "./telemetry.js";
import { initWorkload, renderWorkload } from "./workload.js";

let statusDot = null;

function renderStatusDot(online) {
  if (!statusDot) return;
  statusDot.classList.toggle("status-success", online);
  statusDot.classList.toggle("status-error", !online);
  statusDot.classList.toggle("animate-pulse", online);
  statusDot.dataset.tip = online ? `API live • refresh every ${POLL_INTERVAL_MS / 1000}s` : "API unreachable";
  statusDot.setAttribute("aria-label", online ? "Dashboard API live" : "Dashboard API unreachable");
}

function applyStatus(data) {
  state.active = data.active_model ?? null;
  state.models = data.models ?? [];
  state.services = data.services ?? [];

  const { points, subs } = readTelemetry(data);
  for (const metric of METRICS) {
    if (Number.isFinite(points[metric.id])) pushMetric(metric.id, points[metric.id]);
    setMetricSub(metric.id, subs[metric.id]);
  }

  renderWorkload();
  renderServices(state.services);
  renderModels();
  setPlaygroundTarget(inferenceTarget());
}

async function refresh() {
  try {
    applyStatus(await fetchStatus());
    state.online = true;
  } catch {
    state.online = false;
  }
  renderStatusDot(state.online);
}

async function handleSwitch(name) {
  if (state.switching) return;
  state.switching = true;
  state.pending = name;
  clearPlaygroundTargetPick(); // an explicit switch owns the playground target again
  renderWorkload();
  renderModels();
  try {
    await switchModel(name);
    clearNotify();
  } catch (error) {
    notify(`Model switch failed: ${error.message}`);
  } finally {
    state.switching = false;
    state.pending = null;
    await refresh();
  }
}

async function handleUnload() {
  if (state.switching) return;
  if (!window.confirm("Unload the active workload and release unified memory?")) return;
  state.switching = true;
  state.pending = null;
  renderWorkload();
  try {
    await stopWorkloads();
    clearNotify();
  } catch (error) {
    notify(`Unload failed: ${error.message}`);
  } finally {
    state.switching = false;
    await refresh();
  }
}

function boot() {
  statusDot = document.getElementById("status-dot");

  try {
    initCharts();
  } catch (error) {
    // Telemetry text still works without canvas support.
    console.error("Chart init failed:", error);
  }

  initNotify();
  initServices();
  initModels(handleSwitch);
  initWorkload(handleUnload);
  initPlayground();
  renderWorkload();

  refresh();
  setInterval(refresh, POLL_INTERVAL_MS);
}

boot();
