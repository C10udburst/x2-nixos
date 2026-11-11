// Dashboard entry point: polls /api/status and drives every view.

import { fetchStatus, stopWorkloads, switchModel } from "./api.js";
import { METRICS, initCharts, pushMetric, setMetricSub } from "./charts.js";
import { clearNotify, initNotify, notify } from "./notify.js";
import { clearPlaygroundTargetPick, initPlayground, setPlaygroundTarget } from "./playground.js";
import { initModels, renderModels } from "./models.js";
import { initServices, renderServices } from "./services.js";
import { findModel, modelDevice, POLL_INTERVAL_MS, state } from "./state.js";
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
  const gpu = data.active_gpu_model ?? null;
  const npu = data.active_npu_model ?? null;
  state.active = { gpu, npu };

  // Talk to an older API that only reports one workload: attribute it to its own domain.
  if (!gpu && !npu && data.active_model) {
    state.active[modelDevice(data.active_model)] = data.active_model;
  }

  state.models = data.models ?? [];
  state.services = data.services ?? [];

  const { points, subs } = readTelemetry(data);
  for (const metric of METRICS) {
    if (Number.isFinite(points[metric.id])) pushMetric(metric.id, points[metric.id]);
  }
  for (const [chartId, text] of Object.entries(subs)) {
    setMetricSub(chartId, text);
  }

  renderWorkload();
  renderServices(state.services);
  renderModels();
  setPlaygroundTarget();
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
  const model = findModel(name);
  const device = model ? modelDevice(model) : "gpu";
  if (state.switching.gpu || state.switching.npu) return;
  state.switching[device] = true;
  state.pending = name;
  clearPlaygroundTargetPick(); // an explicit switch owns the playground target again
  renderWorkload();
  renderModels();
  try {
    await switchModel(name); // the API derives the domain from the model itself
    clearNotify();
  } catch (error) {
    notify(`Model switch failed: ${error.message}`);
  } finally {
    state.switching[device] = false;
    state.pending = null;
    await refresh();
  }
}

async function handleUnload(device) {
  if (state.switching[device]) return;
  const label = device === "npu" ? "NPU workload" : "GPU workload";
  const extra = device === "npu" ? "" : " and release unified memory";
  if (!window.confirm(`Unload the active ${label}${extra}? The ${device === "npu" ? "GPU" : "NPU"} workload keeps running.`)) {
    return;
  }
  state.switching[device] = true;
  state.pending = null;
  renderWorkload();
  try {
    await stopWorkloads(device);
    clearNotify();
  } catch (error) {
    notify(`Unload failed: ${error.message}`);
  } finally {
    state.switching[device] = false;
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
