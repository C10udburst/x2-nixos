// Model registry cards, built from the /v1/models registry (see api.js) and narrowed by
// modelFilters.js. The list DOM is rebuilt only when the *visible* subset changes; the
// active/switching state is patched in place so the 2.5s poll never re-renders cards.
//
// Whether a card is active is not registry data - /v1/models is static config. A model is
// loaded exactly when its id is the active workload of its own domain, which /api/status
// reports as active_gpu_model / active_npu_model.

import { escapeHtml, setExclusiveClass } from "./dom.js";
import { formatTokens, sessionLabel } from "./format.js";
import { visibleModels } from "./modelFilters.js";
import { findModel as findModelByName, state } from "./state.js";

const BUTTON_VARIANTS = ["btn-primary", "btn-success"];
const BORDER_VARIANTS = ["border-base-300", "border-success"];
const DEVICE_BADGE = { gpu: "badge-primary", npu: "badge-secondary" };

// Signatures of what the DOM currently holds, so both passes below stay no-ops when the
// visible registry / the workload state did not change.
let registrySignature = "";
let viewSignature = "";

const deviceOf = (model) => (model.device === "npu" ? "npu" : "gpu");
const isActive = (model) => model.name === state.active[deviceOf(model)];

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
          <span class="badge badge-neutral badge-sm font-mono">${escapeHtml(model.backend || "custom")}</span>
          <span class="badge badge-ghost badge-sm font-mono">${escapeHtml(sessionLabel(model.sessions))}</span>
          <span class="badge badge-ghost badge-sm font-mono" title="context window per session">
            ${formatTokens(model.contextLength)} ctx
          </span>
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
  const container = document.getElementById("models-list");
  container.addEventListener("click", (event) => {
    const button = event.target.closest("[data-switch]");
    if (button && !button.disabled) onSwitch(button.dataset.switch);
  });
}

export function renderModels() {
  const container = document.getElementById("models-list");
  if (!container) return;

  const models = state.models.length ? visibleModels() : [];
  if (models.length === 0) {
    const message = state.models.length
      ? `<p class="text-sm opacity-60">No model matches the current filters (${state.models.length} in the registry).</p>`
      : '<p class="text-sm opacity-60">Loading model registry…</p>';
    if (viewSignature !== `empty:${message}`) {
      viewSignature = `empty:${message}`;
      registrySignature = "";
      container.innerHTML = message;
    }
    return;
  }

  // Rebuild the grid only when the visible registry actually differs.
  const nextRegistry = models
    .map((model) =>
      [
        model.name,
        model.backend,
        model.sessions,
        model.device,
        model.contextLength ?? "",
        model.description,
      ].join(":"),
    )
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
