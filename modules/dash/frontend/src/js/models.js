// Model registry cards. The list DOM is built once per registry change; the
// active/switching state is patched in place so polling never re-renders cards.

import { escapeHtml, setExclusiveClass } from "./dom.js";
import { findModel as findModelByName, state } from "./state.js";

const BUTTON_VARIANTS = ["btn-primary", "btn-success"];
const BORDER_VARIANTS = ["border-base-300", "border-success"];

let container = null;
let registrySignature = "";
let viewSignature = "";

function sessionLabel(sessions) {
  const count = sessions || 1;
  return count === 1 ? "1 session" : `${count} sessions`;
}

const DEVICE_BADGE = {
  gpu: "badge-primary",
  npu: "badge-secondary",
};

function deviceOf(model) {
  return model.device === "npu" ? "npu" : "gpu";
}

function isActive(model) {
  return model.name === state.active[deviceOf(model)];
}

function cardMarkup(model) {
  const name = escapeHtml(model.name);
  const device = deviceOf(model);
  const active = isActive(model);
  return `
    <article class="card card-border bg-base-200 shadow ${active ? "border-success" : "border-base-300"}"
             data-model-card="${name}">
      <div class="card-body gap-2 p-4">
        <div class="flex items-start justify-between gap-2">
          <h3 class="card-title break-all font-mono text-sm">${name}</h3>
          <span class="badge badge-success badge-sm" data-model-active ${active ? "" : "hidden"}>ACTIVE</span>
        </div>
        <p class="line-clamp-2 text-sm opacity-70">${escapeHtml(model.description || "No description")}</p>
        <div class="flex flex-wrap gap-2">
          <span class="badge ${DEVICE_BADGE[device]} badge-sm font-mono">${device.toUpperCase()}</span>
          <span class="badge badge-neutral badge-sm font-mono">${escapeHtml(model.backend_type || "custom")}</span>
          <span class="badge badge-ghost badge-sm font-mono">${escapeHtml(sessionLabel(model.sessions))}</span>
          ${(model.capabilities ?? [])
            .map((capability) => `<span class="badge badge-outline badge-sm font-mono">${escapeHtml(capability)}</span>`)
            .join("")}
        </div>
        <div class="card-actions justify-end">
          <button class="btn btn-sm ${active ? "btn-success" : "btn-primary"}" type="button" data-switch="${name}"
                  ${active || state.switching.gpu || state.switching.npu ? "disabled" : ""}>Switch model</button>
        </div>
      </div>
    </article>
  `;
}

export function initModels(onSwitch) {
  container = document.getElementById("models-list");
  container.addEventListener("click", (event) => {
    const button = event.target.closest("[data-switch]");
    if (button && !button.disabled) onSwitch(button.dataset.switch);
  });
}

export function renderModels() {
  if (!container) return;

  const models = state.models || [];
  if (models.length === 0) {
    if (registrySignature !== "empty") {
      registrySignature = "empty";
      viewSignature = "";
      container.innerHTML = '<p class="text-sm opacity-60">No models found in the registry.</p>';
    }
    return;
  }

  const nextRegistry = models
    .map((m) => `${m.name}:${m.backend_type}:${m.sessions}:${m.device}:${(m.capabilities ?? []).join(",")}:${m.description}`)
    .join("|");
  if (nextRegistry !== registrySignature) {
    registrySignature = nextRegistry;
    viewSignature = "";
    container.innerHTML = models.map(cardMarkup).join("");
  }

  const nextView = `${state.active.gpu}|${state.active.npu}|${state.switching.gpu}|${state.switching.npu}`;
  if (nextView === viewSignature) return;
  viewSignature = nextView;

  const switching = state.switching.gpu || state.switching.npu;

  for (const card of container.querySelectorAll("[data-model-card]")) {
    const name = card.dataset.modelCard;
    const model = findModelByName(name);
    const device = model ? deviceOf(model) : "gpu";
    const active = Boolean(model) && isActive(model);

    setExclusiveClass(card, active ? "border-success" : "border-base-300", BORDER_VARIANTS);

    const badge = card.querySelector("[data-model-active]");
    if (badge) badge.hidden = !active;

    const button = card.querySelector("[data-switch]");
    if (!button) continue;
    button.textContent = active
      ? device === "npu"
        ? "Loaded on NPU"
        : "Loaded in VRAM"
      : switching
        ? "Switching…"
        : "Switch model";
    button.disabled = active || switching;
    setExclusiveClass(button, active ? "btn-success" : "btn-primary", BUTTON_VARIANTS);
  }
}
