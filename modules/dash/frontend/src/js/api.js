// Thin wrappers around the FastCGI dashboard API (see ../dash.py) and the /v1 gateway.

const JSON_HEADERS = { "content-type": "application/json" };

async function request(path, init = {}) {
  const res = await fetch(path, init);
  if (!res.ok) {
    const detail = await res.json().catch(() => ({}));
    throw new Error(detail.error || `${path} -> ${res.status} ${res.statusText}`);
  }
  return res;
}

export async function fetchStatus() {
  const res = await fetch("/api/status", { cache: "no-store" });
  if (!res.ok) throw new Error(`/api/status -> ${res.status}`);
  return res.json();
}

// The model registry: an OpenAI /v1/models list generated at Nix eval time and served as a
// static file by nginx (see modules/dash/default.nix). The dashboard loads it ONCE - it is
// configuration, not telemetry - and pairs it with the live active_*_model ids to know what
// is resident. Normalised here so the rest of the app never deals with the wire shape.
export async function fetchModels() {
  const res = await fetch("/v1/models", { cache: "no-store" });
  if (!res.ok) throw new Error(`/v1/models -> ${res.status}`);
  const payload = await res.json();

  return (payload.data ?? []).map((entry) => ({
    name: entry.id,
    description: entry.description ?? "",
    backend: entry.backend || "custom",
    device: entry.device === "npu" ? "npu" : "gpu",
    sessions: Number.isFinite(entry.sessions) ? entry.sessions : 1,
    // null = the runner picks its own window; rendered as an em dash, never as 0.
    contextLength: Number.isFinite(entry.context_length) && entry.context_length > 0
      ? entry.context_length
      : null,
    capabilities: entry.capabilities ?? [],
  }));
}

export async function switchModel(model) {
  await request("/api/switch", {
    method: "POST",
    headers: JSON_HEADERS,
    body: JSON.stringify({ model }),
  });
}

// device: "gpu" | "npu" | "all" - the API defaults to "all", the dashboard always names
// one domain so unloading the NPU never touches a 300 GB GPU model.
export async function stopWorkloads(device = "all") {
  await request("/api/stop", {
    method: "POST",
    headers: JSON_HEADERS,
    body: JSON.stringify({ device }),
  });
}

export function streamChat(body, signal) {
  return fetch("/v1/chat/completions", {
    method: "POST",
    headers: JSON_HEADERS,
    body: JSON.stringify(body),
    signal,
  });
}
