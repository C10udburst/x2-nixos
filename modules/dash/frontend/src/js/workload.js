// Workload cards: one per hardware domain, each with its own unload action.
//
//   GPU  - RDNA 3.5 iGPU, the unified memory pool (LLMs, Immich ML, ComfyUI)
//   NPU  - Ryzen AI XDNA 2 (ONNX / genai artifacts)
//
// Rule 1 applies per domain, so both cards can show a loaded workload at the same time
// and unloading one never touches the other.

import { setExclusiveClass, setText } from "./dom.js";
import { DEVICES, findModel, findService, state } from "./state.js";

const TITLE_COLORS = ["text-primary", "text-success", "text-warning", "text-base-content/40"];

const COPY = {
  gpu: {
    heading: "GPU workload • RDNA 3.5 unified memory",
    idleTitle: "None (0 GB allocated)",
    idleDesc: "Idle. Ready to launch a model or an on-demand service on the first request.",
    switching: "Stopping other GPU workloads and loading the target into unified memory.",
    loadedDesc: "Serving requests.",
    servicePort: true,
  },
  npu: {
    heading: "NPU workload • Ryzen AI XDNA 2",
    idleTitle: "None (NPU idle)",
    idleDesc: "Idle. NPU models start on the first request and run alongside the GPU workload.",
    switching: "Stopping the other NPU workload and loading the target onto the NPU.",
    loadedDesc: "Serving requests on the NPU.",
    servicePort: false,
  },
};

const cards = {};

export function initWorkload(onUnload) {
  for (const device of DEVICES) {
    const card = {
      title: document.getElementById(`workload-${device.id}-title`),
      desc: document.getElementById(`workload-${device.id}-desc`),
      unload: document.getElementById(`btn-unload-${device.id}`),
      badge: document.getElementById(`workload-${device.id}-badge`),
    };
    if (!card.title || !card.unload) continue;
    card.unload.addEventListener("click", () => onUnload(device.id));
    cards[device.id] = card;
  }
}

function renderCard(device) {
  const els = cards[device.id];
  const copy = COPY[device.id];
  if (!els) return;

  const switching = Boolean(state.switching[device.id]);
  if (switching) {
    setText(els.title, state.pending ? `Loading ${state.pending}…` : "Switching workload…");
    setExclusiveClass(els.title, "text-warning", TITLE_COLORS);
    setText(els.desc, copy.switching);
    els.unload.disabled = true;
    return;
  }

  const active = state.active[device.id];

  // On-demand socket services (Immich ML, ComfyUI) belong to the GPU domain.
  const service = findService(active);
  if (service) {
    setText(els.title, service.name);
    setExclusiveClass(els.title, "text-warning", TITLE_COLORS);
    setText(
      els.desc,
      copy.servicePort
        ? `${service.description || "Socket activated service"} • listening on :${service.port}, backend :${service.backend_port ?? service.port}`
        : service.description || "Serving requests on the NPU.",
    );
    els.unload.disabled = false;
    return;
  }

  if (active) {
    const model = findModel(active);
    setText(els.title, active);
    setExclusiveClass(els.title, "text-success", TITLE_COLORS);
    setText(els.desc, model?.description || copy.loadedDesc);
    els.unload.disabled = false;
    return;
  }

  setText(els.title, copy.idleTitle);
  setExclusiveClass(els.title, "text-base-content/40", TITLE_COLORS);
  setText(els.desc, copy.idleDesc);
  els.unload.disabled = true;
}

export function renderWorkload() {
  if (Object.keys(cards).length === 0) return;
  for (const device of DEVICES) renderCard(device);
}
