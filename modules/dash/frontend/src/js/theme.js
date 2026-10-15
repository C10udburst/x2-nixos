// Resolve daisyUI semantic colors into something Lightweight Charts can consume.
//
// daisyUI 5 themes expose `--color-*` as `oklch(...)`, but the charting library
// ships its own strict color parser that only accepts `#hex` / `rgb()` / `rgba()`.
// Round-tripping the value through a canvas fillStyle normalizes any accepted CSS
// color (oklch included) to sRGB, and rejects unsupported ones without throwing.

const FALLBACKS = {
  "base-content": "#cdcdcd",
  "base-300": "#000000",
  primary: "#ff8f00",
  secondary: "#7a00c2",
  accent: "#42aa00",
  info: "#2563eb",
  success: "#18a34a",
  warning: "#d97708",
  error: "#f35248",
};

let probe = null; // CanvasRenderingContext2D | false | null (not probed yet)
const SENTINEL = "#123456";

function canvasProbe() {
  if (probe === null) {
    try {
      probe = document.createElement("canvas").getContext("2d", { willReadFrequently: true }) ?? false;
    } catch {
      probe = false;
    }
  }
  return probe || null;
}

// Chrome hands a canvas `fillStyle` back in its *original* color function, so an
// `oklch(...)` theme value round-trips as `oklch(...)` and still blows up inside the
// chart library. Rasterizing a single pixel is the only normalization that always
// resolves to sRGB bytes. Returns null when the browser rejects the color.
export function normalizeColor(value) {
  const raw = typeof value === "string" ? value.trim() : "";
  const context = canvasProbe();
  if (!context || !raw) return null;

  try {
    context.fillStyle = SENTINEL;
    context.fillStyle = raw;
    // An unaccepted value leaves fillStyle untouched.
    if (context.fillStyle === SENTINEL && raw !== SENTINEL) return null;
    context.clearRect(0, 0, 1, 1);
    context.fillRect(0, 0, 1, 1);
    const [r, g, b] = context.getImageData(0, 0, 1, 1).data;
    return `#${[r, g, b].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  } catch {
    return null;
  }
}

export function cssColor(name) {
  const raw = getComputedStyle(document.documentElement)
    .getPropertyValue(`--color-${name}`)
    .trim();
  return normalizeColor(raw) ?? FALLBACKS[name] ?? "#808080";
}

// Lightweight Charts needs literal rgba() for translucent area fills.
export function withAlpha(color, alpha) {
  const rgb = parseRgb(color) ?? parseRgb(normalizeColor(color) ?? "");
  return rgb ? `rgba(${rgb.join(", ")}, ${alpha})` : color;
}

export function parseRgb(color) {
  if (typeof color !== "string") return null;
  const value = color.trim();

  const hex = value.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (hex) {
    const digits = hex[1];
    const byte = (pair) => parseInt(pair.length === 1 ? pair + pair : pair, 16);
    return digits.length === 3
      ? [byte(digits[0]), byte(digits[1]), byte(digits[2])]
      : [byte(digits.slice(0, 2)), byte(digits.slice(2, 4)), byte(digits.slice(4, 6))];
  }

  const functional = value.match(/^rgba?\(([^)]+)\)$/i);
  if (functional) {
    const parts = functional[1].split(/[\s,/]+/).filter(Boolean).slice(0, 3);
    if (parts.length === 3 && parts.every((part) => Number.isFinite(Number(part)))) {
      return parts.map((part) => Math.round(Number(part)));
    }
  }
  return null;
}
