// Live telemetry charts (Lightweight Charts(TM) by TradingView).
// One auto-scaling area series per metric, fed by the /api/status poll.
// Numeric readouts are updated independently of the canvas, so the cards stay
// useful even when charting is unavailable.

import { AreaSeries, ColorType, CrosshairMode, createChart } from "lightweight-charts";
import { cssColor, withAlpha } from "./theme.js";

const HISTORY_KEY = "evo-x2-telemetry";
const MAX_POINTS = 240; // ~10 minutes at the 2.5s poll interval

export const METRICS = [
  { id: "ram", color: "success", decimals: 1, unit: " GB" },
  { id: "vram", color: "secondary", decimals: 1, unit: " GB" },
  { id: "gpu", color: "info", decimals: 0, unit: "%" },
  { id: "cpu", color: "warning", decimals: 2, unit: "" },
];

export function formatMetric(metric, value) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "--";
  return `${value.toFixed(metric.decimals)}${metric.unit}`;
}

const readouts = new Map(); // metric id -> { metric, valueEl, subEl }
const plots = new Map(); // metric id -> { chart, series, latest }
const buffers = new Map(); // metric id -> [{ time, value }]
let pushes = 0;

function partsFor(metricId) {
  const card = document.querySelector(`[data-metric="${metricId}"]`);
  if (!card) return null;
  return {
    valueEl: card.querySelector("[data-value]"),
    chartEl: card.querySelector("[data-chart]"),
    subEl: card.querySelector("[data-sub]"),
  };
}

function showValue(metricId, value) {
  const readout = readouts.get(metricId);
  if (readout?.valueEl) readout.valueEl.textContent = formatMetric(readout.metric, value);
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

function createPlot(metric, chartEl, textColor, gridColor) {
  const line = cssColor(metric.color);
  const chart = createChart(chartEl, {
    autoSize: true,
    layout: {
      background: { type: ColorType.Solid, color: "transparent" },
      textColor,
      fontSize: 10,
      // This is a local only service, so we don't need attribution, only I will use the dashboard
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

  const series = chart.addSeries(AreaSeries, {
    lineColor: line,
    topColor: withAlpha(line, 0.45),
    bottomColor: withAlpha(line, 0.03),
    lineWidth: 2,
    priceLineVisible: false,
    lastValueVisible: false,
    crosshairMarkerRadius: 3,
  });

  const data = buffers.get(metric.id) ?? [];
  if (data.length > 0) series.setData(data);

  const plot = { chart, series, latest: data.at(-1)?.value ?? null };
  plots.set(metric.id, plot);

  // Hovering a point previews that sample instead of the live one.
  chart.subscribeCrosshairMove((param) => {
    const point = param.time ? param.seriesData.get(series) : null;
    showValue(metric.id, point ? point.value : plot.latest);
  });
}

export function initCharts() {
  const history = loadHistory();
  const textColor = cssColor("base-content");
  const gridColor = withAlpha(textColor, 0.1);

  for (const metric of METRICS) {
    const parts = partsFor(metric.id);
    if (!parts) continue;

    const restored = Array.isArray(history[metric.id]) ? history[metric.id] : [];
    buffers.set(metric.id, restored);
    readouts.set(metric.id, { metric, valueEl: parts.valueEl, subEl: parts.subEl });
    showValue(metric.id, restored.at(-1)?.value ?? null);

    try {
      createPlot(metric, parts.chartEl, textColor, gridColor);
    } catch (error) {
      console.error(`telemetry chart "${metric.id}" unavailable:`, error);
    }
  }
}

export function pushMetric(id, value) {
  if (!Number.isFinite(value)) return;

  const time = Math.floor(Date.now() / 1000);
  const data = buffers.get(id);
  if (!data) return;

  const last = data.at(-1);
  if (last && time < last.time) return;

  const point = { time, value };
  if (last && last.time === time) data[data.length - 1] = point;
  else data.push(point);
  if (data.length > MAX_POINTS) data.splice(0, data.length - MAX_POINTS);

  const plot = plots.get(id);
  if (plot) {
    plot.series.update(point);
    plot.latest = value;
    if (last && last.time !== time) plot.chart.timeScale().scrollToRealTime();
  }

  showValue(id, value);
  pushes += 1;
  if (pushes % METRICS.length === 0) saveHistory();
}

export function setMetricSub(id, text) {
  const readout = readouts.get(id);
  if (readout?.subEl && text && readout.subEl.textContent !== text) readout.subEl.textContent = text;
}
