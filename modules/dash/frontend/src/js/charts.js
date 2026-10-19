// Live telemetry charts (Lightweight Charts(TM) by TradingView).
// Multi-series auto-scaling charts, fed by the /api/status poll.
// Interactive legend chips allow hiding/showing individual series.
// Numeric readouts and floating tooltips are updated on crosshair movement.

import { AreaSeries, LineSeries, ColorType, CrosshairMode, createChart } from "lightweight-charts";
import { cssColor, withAlpha } from "./theme.js";

const HISTORY_KEY = "evo-x2-telemetry";
const MAX_POINTS = 240; // ~10 minutes at the 2.5s poll interval

const COLOR_CLASSES = {
  warning: "text-warning",
  info: "text-info",
  success: "text-success",
  secondary: "text-secondary",
  primary: "text-primary",
  accent: "text-accent",
};

export const METRICS = [
  { id: "ram", chartId: "ram" },
  { id: "vram", chartId: "ram" },
  { id: "gtt", chartId: "ram" },
  { id: "cpu", chartId: "load" },
  { id: "gpu", chartId: "load" },
  { id: "npu", chartId: "load" },
  { id: "cpu_temp", chartId: "temp" },
  { id: "gpu_temp", chartId: "temp" },
  { id: "npu_temp", chartId: "temp" },
];

export const CHARTS = [
  {
    id: "ram",
    series: [
      { key: "ram", color: "success", label: "RAM", decimals: 1, unit: " GB", type: "line" },
      { key: "vram", color: "primary", label: "VRAM", decimals: 1, unit: " GB", type: "line" },
      { key: "gtt", color: "secondary", label: "GTT", decimals: 1, unit: " GB", type: "line" },
    ],
  },
  {
    id: "load",
    series: [
      { key: "cpu", color: "warning", label: "CPU", decimals: 0, unit: "%", type: "line" },
      { key: "gpu", color: "info", label: "GPU", decimals: 0, unit: "%", type: "line" },
      { key: "npu", color: "accent", label: "NPU", decimals: 0, unit: "%", type: "line" },
    ],
  },
  {
    id: "temp",
    series: [
      { key: "cpu_temp", color: "warning", label: "CPU", decimals: 1, unit: "°C", type: "line" },
      { key: "gpu_temp", color: "info", label: "GPU", decimals: 1, unit: "°C", type: "line" },
      { key: "npu_temp", color: "accent", label: "NPU", decimals: 1, unit: "°C", type: "line" },
    ],
  },
];

const readouts = new Map(); // chart id -> { chartDef, valueEl, subEl }
const plots = new Map(); // chart id -> { chart, seriesMap, latest }
const buffers = new Map(); // series key -> [{ time, value }]
const seriesToChart = new Map(); // series key -> chart id
const hiddenSeries = new Set(); // series keys currently hidden

for (const c of CHARTS) {
  for (const s of c.series) {
    seriesToChart.set(s.key, c.id);
  }
}

let pushes = 0;

function partsFor(chartId) {
  const card = document.querySelector(`[data-metric="${chartId}"]`);
  if (!card) return null;
  return {
    valueEl: card.querySelector("[data-value]"),
    chartEl: card.querySelector("[data-chart]"),
    subEl: card.querySelector("[data-sub]"),
  };
}

function updateChipState(chartId, seriesKey) {
  const readout = readouts.get(chartId);
  if (!readout?.valueEl) return;
  const chip = readout.valueEl.querySelector(`[data-series-key="${seriesKey}"]`);
  if (!chip) return;

  const sDef = readout.chartDef.series.find((s) => s.key === seriesKey);
  const isHidden = hiddenSeries.has(seriesKey);

  chip.setAttribute("aria-pressed", (!isHidden).toString());
  chip.title = isHidden ? `Click to show ${sDef?.label || seriesKey}` : `Click to hide ${sDef?.label || seriesKey}`;

  const dot = chip.querySelector("[data-series-dot]");
  if (isHidden) {
    chip.className =
      "badge badge-sm cursor-pointer select-none gap-1 font-mono text-xs transition-all border border-dashed border-base-content/25 bg-transparent text-base-content/50 opacity-40 hover:opacity-75 line-through";
    if (dot) dot.style.opacity = "0.2";
  } else {
    chip.className =
      "badge badge-sm cursor-pointer select-none gap-1 font-mono text-xs transition-all border border-base-content/15 bg-base-300/80 hover:bg-base-300 text-base-content shadow-xs";
    if (dot) dot.style.opacity = "1";
  }
}

function toggleSeries(chartId, seriesKey) {
  const plot = plots.get(chartId);
  if (!plot) return;
  const series = plot.seriesMap.get(seriesKey);
  if (!series) return;

  if (hiddenSeries.has(seriesKey)) {
    hiddenSeries.delete(seriesKey);
    series.applyOptions({ visible: true });
  } else {
    hiddenSeries.add(seriesKey);
    series.applyOptions({ visible: false });
  }

  updateChipState(chartId, seriesKey);
}

function buildLegendChips(chartDef, valueEl) {
  valueEl.innerHTML = "";
  for (const sDef of chartDef.series) {
    const hex = cssColor(sDef.color);
    const colorCls = COLOR_CLASSES[sDef.color] || "";

    const chip = document.createElement("button");
    chip.type = "button";
    chip.dataset.seriesKey = sDef.key;
    chip.className =
      "badge badge-sm cursor-pointer select-none gap-1 font-mono text-xs transition-all border border-base-content/15 bg-base-300/80 hover:bg-base-300 text-base-content shadow-xs";
    chip.title = `Click to hide ${sDef.label}`;
    chip.setAttribute("aria-pressed", "true");
    chip.innerHTML = `
      <span class="inline-block h-2 w-2 rounded-full shrink-0 transition-opacity" data-series-dot style="background-color: ${hex}"></span>
      <span class="${colorCls} font-semibold">${sDef.label}</span>
      <span class="font-bold ml-0.5" data-series-val="${sDef.key}">--</span>
    `;

    chip.addEventListener("click", (e) => {
      e.stopPropagation();
      toggleSeries(chartDef.id, sDef.key);
    });

    valueEl.appendChild(chip);
  }
}

function showValues(chartId, values) {
  const readout = readouts.get(chartId);
  if (!readout?.valueEl) return;
  for (const sDef of readout.chartDef.series) {
    const valEl = readout.valueEl.querySelector(`[data-series-val="${sDef.key}"]`);
    if (!valEl) continue;
    const val = values[sDef.key];
    valEl.textContent = (val !== null && val !== undefined && Number.isFinite(val))
      ? `${val.toFixed(sDef.decimals)}${sDef.unit}`
      : "--";
  }
}

function loadHistory() {
  try {
    return JSON.parse(sessionStorage.getItem(HISTORY_KEY)) || {};
  } catch {
    return {};
  }
}

function saveHistory() {
  const payload = Object.fromEntries(buffers);
  try {
    sessionStorage.setItem(HISTORY_KEY, JSON.stringify(payload));
  } catch {
    /* quota or private mode: history is best-effort */
  }
}

function createPlot(chartDef, chartEl, textColor, gridColor) {
  chartEl.style.position = "relative";

  const chart = createChart(chartEl, {
    autoSize: true,
    layout: {
      background: { type: ColorType.Solid, color: "transparent" },
      textColor,
      fontSize: 10,
      attributionLogo: false,
    },
    grid: { vertLines: { visible: false }, horzLines: { color: gridColor } },
    rightPriceScale: { visible: false, scaleMargins: { top: 0.2, bottom: 0.05 } },
    timeScale: { visible: false, rightOffset: 1, barSpacing: 6, minBarSpacing: 2 },
    crosshair: {
      mode: CrosshairMode.Index,
      vertLine: { labelVisible: false, tickVisible: false },
      horzLine: { labelVisible: false, tickVisible: false },
    },
    handleScroll: false,
    handleScale: false,
  });

  const tooltip = document.createElement("div");
  tooltip.className =
    "pointer-events-none absolute z-20 hidden rounded border border-base-300 bg-base-300/95 px-2 py-1 font-mono text-xs shadow-lg backdrop-blur";
  chartEl.appendChild(tooltip);

  const seriesMap = new Map();
  const latest = {};

  for (const sDef of chartDef.series) {
    const line = cssColor(sDef.color);
    let series;
    if (sDef.type === "line") {
      series = chart.addSeries(LineSeries, {
        color: line,
        lineWidth: 2,
        priceLineVisible: false,
        lastValueVisible: false,
        crosshairMarkerRadius: 3,
      });
    } else {
      series = chart.addSeries(AreaSeries, {
        lineColor: line,
        topColor: withAlpha(line, 0.45),
        bottomColor: withAlpha(line, 0.03),
        lineWidth: 2,
        priceLineVisible: false,
        lastValueVisible: false,
        crosshairMarkerRadius: 3,
      });
    }

    const data = buffers.get(sDef.key) ?? [];
    if (data.length > 0) series.setData(data);

    seriesMap.set(sDef.key, series);
    latest[sDef.key] = data.at(-1)?.value ?? null;
  }

  plots.set(chartDef.id, { chart, seriesMap, latest });

  // Crosshair move handler drives both the card header readout and the floating tooltip.
  chart.subscribeCrosshairMove((param) => {
    if (!param.time || !param.point) {
      showValues(chartDef.id, latest);
      tooltip.classList.add("hidden");
      return;
    }

    const hovered = {};
    const rows = [];
    for (const sDef of chartDef.series) {
      const sApi = seriesMap.get(sDef.key);
      const point = sApi ? param.seriesData.get(sApi) : null;
      const val = point ? point.value : latest[sDef.key];
      hovered[sDef.key] = val;

      if (hiddenSeries.has(sDef.key)) continue;

      const formatted = (val !== null && val !== undefined && Number.isFinite(val))
        ? `${val.toFixed(sDef.decimals)}${sDef.unit}`
        : "--";
      const colorCls = COLOR_CLASSES[sDef.color] || "";
      const hex = cssColor(sDef.color);
      rows.push(`
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-1.5">
            <span class="inline-block h-2 w-2 rounded-full" style="background-color: ${hex}"></span>
            <span class="${colorCls} text-xs">${sDef.label}:</span>
          </div>
          <span class="font-bold text-xs">${formatted}</span>
        </div>
      `);
    }

    showValues(chartDef.id, hovered);

    if (rows.length === 0) {
      tooltip.classList.add("hidden");
      return;
    }

    const timeDate = new Date(param.time * 1000);
    const timeStr = timeDate.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

    tooltip.innerHTML = `
      <div class="flex flex-col gap-1 min-w-28">
        <div class="text-[10px] opacity-50">${timeStr}</div>
        ${rows.join("")}
      </div>
    `;
    tooltip.classList.remove("hidden");

    const containerWidth = chartEl.clientWidth;
    const containerHeight = chartEl.clientHeight;
    const tipWidth = tooltip.offsetWidth || 130;
    const tipHeight = tooltip.offsetHeight || 50;

    let left = param.point.x + 12;
    if (left + tipWidth > containerWidth - 8) {
      left = param.point.x - tipWidth - 12;
    }
    left = Math.max(8, left);

    let top = param.point.y - tipHeight / 2;
    top = Math.max(4, Math.min(containerHeight - tipHeight - 4, top));

    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;
  });

  chartEl.addEventListener("mouseleave", () => {
    tooltip.classList.add("hidden");
    showValues(chartDef.id, latest);
  });
}

export function initCharts() {
  const history = loadHistory();
  const textColor = cssColor("base-content");
  const gridColor = withAlpha(textColor, 0.1);

  for (const chartDef of CHARTS) {
    const parts = partsFor(chartDef.id);
    if (!parts) continue;

    readouts.set(chartDef.id, { chartDef, valueEl: parts.valueEl, subEl: parts.subEl });
    if (parts.valueEl) {
      buildLegendChips(chartDef, parts.valueEl);
    }

    const initialValues = {};
    for (const sDef of chartDef.series) {
      const restored = Array.isArray(history[sDef.key]) ? history[sDef.key] : [];
      buffers.set(sDef.key, restored);
      initialValues[sDef.key] = restored.at(-1)?.value ?? null;
    }

    showValues(chartDef.id, initialValues);

    try {
      createPlot(chartDef, parts.chartEl, textColor, gridColor);
    } catch (error) {
      console.error(`telemetry chart "${chartDef.id}" unavailable:`, error);
    }
  }
}

export function pushMetric(seriesKey, value) {
  if (!Number.isFinite(value)) return;

  const chartId = seriesToChart.get(seriesKey);
  if (!chartId) return;

  const time = Math.floor(Date.now() / 1000);
  const data = buffers.get(seriesKey);
  if (!data) return;

  const last = data.at(-1);
  if (last && time < last.time) return;

  const point = { time, value };
  if (last && last.time === time) data[data.length - 1] = point;
  else data.push(point);
  if (data.length > MAX_POINTS) data.splice(0, data.length - MAX_POINTS);

  const plot = plots.get(chartId);
  if (plot) {
    const series = plot.seriesMap.get(seriesKey);
    if (series) {
      series.update(point);
      plot.latest[seriesKey] = value;
      if (last && last.time !== time) plot.chart.timeScale().scrollToRealTime();
    }
    showValues(chartId, plot.latest);
  }

  pushes += 1;
  if (pushes % METRICS.length === 0) saveHistory();
}

export function setMetricSub(chartId, text) {
  const readout = readouts.get(chartId);
  if (readout?.subEl && text && readout.subEl.textContent !== text) readout.subEl.textContent = text;
}
