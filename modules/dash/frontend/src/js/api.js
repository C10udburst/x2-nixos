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

// A cold engine can take minutes (SGLang imports torch and JIT-compiles Triton kernels),
// so the browser must not give up before the gateway's own budget expires. The AbortSignal
// also covers nginx closing an idle FastCGI response early.
const SWITCH_TIMEOUT_MS = 20 * 60 * 1000;

export async function switchModel(model) {
  const timer = new AbortController();
  const timeout = setTimeout(() => timer.abort(), SWITCH_TIMEOUT_MS);
  try {
    await request("/api/switch", {
      method: "POST",
      headers: JSON_HEADERS,
      body: JSON.stringify({ model }),
      signal: timer.signal,
    });
  } catch (error) {
    if (error.name === "AbortError") throw new Error("switch timed out after 20 min");
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

export async function stopWorkloads() {
  await request("/api/stop", { method: "POST" });
}

export function streamChat(body, signal) {
  return fetch("/v1/chat/completions", {
    method: "POST",
    headers: JSON_HEADERS,
    body: JSON.stringify(body),
    signal,
  });
}
