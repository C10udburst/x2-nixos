// Active workload card: which heavy unit currently owns the unified memory pool.

import { setExclusiveClass, setText } from "./dom.js";
import { findModel, findService, state } from "./state.js";

const TITLE_COLORS = ["text-primary", "text-success", "text-warning", "text-base-content/40"];

let els = null;

export function initWorkload(onUnload) {
  els = {
    title: document.getElementById("workload-title"),
    desc: document.getElementById("workload-desc"),
    unload: document.getElementById("btn-unload"),
  };
  els.unload.addEventListener("click", onUnload);
}

export function renderWorkload() {
  if (!els) return;

  if (state.switching) {
    setText(els.title, state.pending ? `Loading ${state.pending}…` : "Switching workload…");
    setExclusiveClass(els.title, "text-warning", TITLE_COLORS);
    setText(els.desc, "Stopping other workloads and loading the target into unified memory.");
    els.unload.disabled = true;
    return;
  }

  const service = findService(state.active);
  if (service) {
    setText(els.title, service.name);
    setExclusiveClass(els.title, "text-warning", TITLE_COLORS);
    setText(
      els.desc,
      `${service.description || "Socket activated service"} • listening on :${service.port}, backend :${service.backend_port ?? service.port}`,
    );
    els.unload.disabled = false;
    return;
  }

  if (state.active) {
    const model = findModel(state.active);
    setText(els.title, state.active);
    setExclusiveClass(els.title, "text-success", TITLE_COLORS);
    setText(els.desc, model?.description || "Serving requests.");
    els.unload.disabled = false;
    return;
  }

  setText(els.title, "None (0 GB allocated)");
  setExclusiveClass(els.title, "text-base-content/40", TITLE_COLORS);
  setText(els.desc, "Idle. Ready to launch a model or an on-demand service on the first request.");
  els.unload.disabled = true;
}
