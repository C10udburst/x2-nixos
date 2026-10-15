// Resolve daisyUI semantic colors for canvas rendering (Lightweight Charts needs
// literal CSS colors, it cannot evaluate var(...)). Hex fallbacks match the halloween theme.

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

export function cssColor(name) {
  const resolved = getComputedStyle(document.documentElement)
    .getPropertyValue(`--color-${name}`)
    .trim();
  return resolved || FALLBACKS[name] || "#808080";
}

// CSS Color 4 alpha syntax works for every functional notation: oklch(21% 0 0 / 0.15)
export function withAlpha(color, alpha) {
  const close = color.lastIndexOf(")");
  if (!color.includes("(") || close < 0 || color.includes("/")) return color;
  return `${color.slice(0, close)} / ${alpha})`;
}
