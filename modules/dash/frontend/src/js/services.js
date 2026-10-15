// Footer service list: status dot, name and a clickable port per subsystem.

import { escapeHtml } from "./dom.js";

const DOT = {
  active: "status-success animate-pulse",
  standby: "status-info",
  inactive: "status-neutral",
};

const LABEL = {
  active: "active",
  standby: "standby (0 MB)",
  inactive: "stopped",
};

let container = null;
let signature = "";

export function initServices() {
  container = document.getElementById("service-list");
}

export function renderServices(services) {
  if (!container) return;

  if (!services || services.length === 0) {
    if (signature !== "empty") {
      signature = "empty";
      container.innerHTML = '<p class="text-xs opacity-40">No declared services.</p>';
    }
    return;
  }

  const nextSignature = services.map((service) => `${service.id}:${service.status}:${service.port}`).join("|");
  if (nextSignature === signature) return;
  signature = nextSignature;

  const scheme = location.protocol === "https:" ? "https" : "http";
  const host = location.hostname || "localhost";

  container.innerHTML = services
    .map((service) => {
      const dot = DOT[service.status] ?? DOT.inactive;
      const label = LABEL[service.status] ?? String(service.status ?? "unknown");
      const port = escapeHtml(service.port);
      return `
        <span class="flex items-center gap-2">
          <span class="status ${dot}" title="${label}"></span>
          <span>${escapeHtml(service.name)}</span>
          <a class="link link-primary font-mono" href="${scheme}://${host}:${port}"
             target="_blank" rel="noopener noreferrer">:${port}</a>
        </span>
      `;
    })
    .join("");
}
