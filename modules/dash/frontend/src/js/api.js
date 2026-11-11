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
