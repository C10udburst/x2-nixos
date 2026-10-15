// Transient error banner (daisyUI alert).

import { setText } from "./dom.js";

let el = null;
let timer = null;

export function initNotify() {
  el = document.getElementById("notify");
}

export function notify(message) {
  if (!el) return;
  setText(el, message);
  el.classList.remove("hidden");
  clearTimeout(timer);
  timer = setTimeout(() => el.classList.add("hidden"), 8000);
}

export function clearNotify() {
  if (!el) return;
  clearTimeout(timer);
  el.classList.add("hidden");
}
