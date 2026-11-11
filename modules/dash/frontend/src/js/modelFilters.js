// Registry filters: free-text search, engine/backend + session multiselects, and a popout
// dual-thumb range over the declared context window.
//
// The registry is static config (fetched once from /v1/models), so the option lists and the
// context scale are derived once, when it arrives; every interaction only recomputes the
// visible subset. models.js paints whatever `visibleModels()` returns and nothing in here
// touches the network or the workload state.

import { escapeHtml, setText } from "./dom.js";
import { formatTokens } from "./format.js";
import { state } from "./state.js";

// The range slider works in 100 steps mapped log2 over the windows the registry actually
// declares, so a 8K … 1M span drags evenly instead of parking everything at the left edge.
const STEPS = 100;

// Keep in sync with `--dual-thumb` in ../css/app.css: a native thumb's centre travels
// (width - thumb) px, and the highlighted segment is aligned to exactly that.
const THUMB_PX = 16;

/* ---------------------------------------------------------------- context scale */

let scale = { minExp: 12, maxExp: 21 }; // placeholder until the registry lands

function computeScale() {
  const contexts = state.models
    .map((model) => model.contextLength)
    .filter((value) => Number.isFinite(value) && value > 0);
  if (contexts.length === 0) return scale;
  const minExp = Math.floor(Math.log2(Math.min(...contexts)));
  const maxExp = Math.max(minExp + 1, Math.ceil(Math.log2(Math.max(...contexts))));
  return { minExp, maxExp };
}

const sliderToContext = (step) =>
  2 ** (scale.minExp + (step / STEPS) * (scale.maxExp - scale.minExp));

/* ------------------------------------------------------------- widget: multiselect */

// A dropdown of checkboxes where "everything checked" is stored as an empty restriction, so
// the default state costs nothing and `matches()` stays a one-liner.
class Multiselect {
  constructor(host, title, { readValue = (raw) => raw, onChange = () => {} } = {}) {
    this.values = [];
    this.selected = new Set(); // empty = no restriction
    this.readValue = readValue;
    this.onChange = onChange;

    host.innerHTML = `
      <div class="dropdown dropdown-bottom">
        <div tabindex="0" role="button" class="btn btn-sm btn-ghost gap-2 border border-base-300 font-mono"
             title="Filter by ${escapeHtml(title.toLowerCase())}">
          <span class="opacity-60">${escapeHtml(title)}</span>
          <span class="badge badge-sm badge-neutral" data-count>all</span>
        </div>
        <div tabindex="0" class="dropdown-content z-10 flex w-44 flex-col gap-2 rounded-box border border-base-300 bg-base-200 p-2 shadow-lg">
          <div data-options class="flex max-h-56 flex-col gap-1 overflow-y-auto"></div>
          <button type="button" class="btn btn-xs btn-ghost justify-start" data-all>select all</button>
        </div>
      </div>`;

    this.options = host.querySelector("[data-options]");
    this.count = host.querySelector("[data-count]");

    this.options.addEventListener("change", (event) => {
      const box = event.target.closest("input[type=checkbox]");
      if (box) this.toggle(this.readValue(box.value), box.checked);
    });
    host.querySelector("[data-all]").addEventListener("click", () => this.reset());
  }

  setOptions(values, format) {
    this.values = values;
    this.options.innerHTML = values
      .map(
        (value) => `
        <label class="flex cursor-pointer items-center gap-2 font-mono text-xs">
          <input type="checkbox" class="checkbox checkbox-xs checkbox-primary" value="${escapeHtml(String(value))}" />
          <span>${escapeHtml(format(value))}</span>
        </label>`,
      )
      .join("");
    this.paint();
  }

  // An explicit "all" pick, or an empty option list, both mean "no restriction".
  get active() {
    return this.selected.size > 0 && this.values.length > 0;
  }

  matches(value) {
    return !this.active || this.selected.has(value);
  }

  reset() {
    this.clearSelection();
    this.onChange();
  }

  clearSelection() {
    this.selected.clear();
    this.paint();
  }

  paint() {
    // Unrestricted means every box ticked; restricted means only the kept ones are.
    for (const box of this.options.querySelectorAll("input[type=checkbox]")) {
      box.checked = !this.active || this.selected.has(this.readValue(box.value));
    }
    setText(this.count, this.active ? String(this.selected.size) : "all");
    this.count.classList.toggle("badge-primary", this.active);
    this.count.classList.toggle("badge-neutral", !this.active);
  }

  toggle(value, checked) {
    const next = new Set(this.selected.size ? this.selected : this.values);
    if (checked) next.add(value);
    else next.delete(value);
    // Still everything? Collapse back to the unrestricted state.
    this.selected = next.size === this.values.length ? new Set() : next;
    this.paint();
    this.onChange();
  }
}

/* ------------------------------------------------------------------------- state */

const filters = { query: "", lo: 0, hi: STEPS };
let els = null;
let backends = null;
let sessions = null;
let onChange = () => {};
let optionsSignature = "";

const narrowed = () => filters.lo > 0 || filters.hi < STEPS;

function filtersActive() {
  return Boolean(filters.query) || backends.active || sessions.active || narrowed();
}

// The subset of the registry the grid shows, in registry order.
export function visibleModels() {
  const query = filters.query.trim().toLowerCase();
  const min = narrowed() ? sliderToContext(filters.lo) : 0;
  const max = narrowed() ? sliderToContext(filters.hi) : Infinity;

  return state.models.filter((model) => {
    if (query && !`${model.name} ${model.description}`.toLowerCase().includes(query)) return false;
    if (!backends.matches(model.backend)) return false;
    if (!sessions.matches(model.sessions || 1)) return false;
    // Undeclared window: it cannot be proven to fit, so it only survives an untouched range.
    if (narrowed() && !(model.contextLength >= min && model.contextLength <= max)) return false;
    return true;
  });
}

/* ------------------------------------------------------------------------ wiring */

// Derive the option lists and the slider bounds from the registry. Idempotent: the registry
// never changes at runtime, so polling it again is a cheap signature check.
export function syncFilterOptions() {
  if (!els) return false;
  const signature = state.models
    .map((model) => `${model.backend}/${model.sessions}/${model.contextLength ?? ""}`)
    .join("|");
  if (signature === optionsSignature) return false;
  optionsSignature = signature;

  scale = computeScale();
  backends.setOptions(
    [...new Set(state.models.map((model) => model.backend))].sort(),
    (backend) => backend,
  );
  sessions.setOptions(
    [...new Set(state.models.map((model) => model.sessions || 1))].sort((a, b) => a - b),
    (count) => (count === 1 ? "1 session" : `${count} sessions`),
  );
  setRange(filters.lo, filters.hi);
  return true;
}

// Patch every label to the current filter state.
export function renderModelFilters() {
  if (!els) return;
  backends.paint();
  sessions.paint();

  const label = narrowed()
    ? `${formatTokens(Math.round(sliderToContext(filters.lo)))} – ${formatTokens(Math.round(sliderToContext(filters.hi)))}`
    : `${formatTokens(2 ** scale.minExp)} – ${formatTokens(2 ** scale.maxExp)}`;
  setText(els.contextLabel, label);
  els.contextLabel.classList.toggle("badge-primary", narrowed());
  els.contextLabel.classList.toggle("badge-neutral", !narrowed());

  setText(els.count, `${visibleModels().length} of ${state.models.length}`);
  els.clear.hidden = !filtersActive();
}

function setRange(lo, hi) {
  filters.lo = Math.min(lo, hi);
  filters.hi = Math.max(lo, hi);
  els.rangeMin.value = String(filters.lo);
  els.rangeMax.value = String(filters.hi);

  // The highlighted segment is positioned in fractions of the *usable* track (the thumb
  // centre cannot reach the last thumb-width). Percentages keep it correct even while the
  // popout is closed - a closed daisyUI dropdown is display:none and measures nothing.
  const usable = `(100% - ${THUMB_PX}px)`;
  els.fill.style.left = `calc(${THUMB_PX / 2}px + ${(filters.lo / STEPS).toFixed(4)} * ${usable})`;
  els.fill.style.width = `calc(${((filters.hi - filters.lo) / STEPS).toFixed(4)} * ${usable})`;
  setText(els.min, formatTokens(Math.round(sliderToContext(filters.lo))));
  setText(els.max, formatTokens(Math.round(sliderToContext(filters.hi))));
}

function notify() {
  renderModelFilters();
  onChange();
}

export function resetFilters() {
  filters.query = "";
  els.search.value = "";
  backends.clearSelection();
  sessions.clearSelection();
  setRange(0, STEPS);
  notify(); // one repaint for the whole reset
}

export function initModelFilters(changed) {
  onChange = changed;

  const range = document.getElementById("filter-context-range");
  els = {
    search: document.getElementById("filter-search"),
    contextLabel: document.getElementById("filter-context-label"),
    range,
    rangeMin: range.querySelector("[data-range=min]"),
    rangeMax: range.querySelector("[data-range=max]"),
    fill: range.querySelector(".dual-range-fill"),
    min: document.getElementById("filter-context-min"),
    max: document.getElementById("filter-context-max"),
    clear: document.getElementById("btn-clear-filters"),
    count: document.getElementById("models-count"),
  };

  backends = new Multiselect(document.getElementById("filter-backend"), "Engine", {
    onChange: notify,
  });
  sessions = new Multiselect(document.getElementById("filter-sessions"), "Sessions", {
    readValue: Number,
    onChange: notify,
  });

  els.search.addEventListener("input", () => {
    filters.query = els.search.value;
    notify();
  });

  // Two stacked native ranges: each handle owns one end and cannot pass the other.
  els.rangeMin.addEventListener("input", () => {
    setRange(Number(els.rangeMin.value), filters.hi);
    notify();
  });
  els.rangeMax.addEventListener("input", () => {
    setRange(filters.lo, Number(els.rangeMax.value));
    notify();
  });

  els.clear.addEventListener("click", resetFilters);
  setRange(0, STEPS);
}
