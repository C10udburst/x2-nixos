// Small DOM helpers: avoid touching nodes that already hold the right value,
// so the 2.5s refresh loop never causes flicker.

export function setText(el, text) {
  const next = text ?? "";
  if (el && el.textContent !== next) el.textContent = next;
}

// Keep exactly one class of a mutually exclusive group (e.g. text colors).
export function setExclusiveClass(el, active, all) {
  if (!el) return;
  for (const cls of all) el.classList.toggle(cls, cls === active);
}

export function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char]);
}
