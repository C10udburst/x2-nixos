// Shared client state for the dashboard.
//
// The box runs two independent workload domains: the GPU (RDNA 3.5 unified memory pool)
// and the NPU (Ryzen AI XDNA 2). Each holds at most one workload, and one domain can be
// loaded while the other is idle or busy.
//
// Two sources feed this state: /v1/models (static registry, loaded once) and /api/status
// (telemetry + the active workload id per domain, polled).

export const POLL_INTERVAL_MS = 2500;

export const DEVICES = [
  { id: "gpu", label: "GPU", hint: "RDNA 3.5 iGPU • unified memory pool" },
  { id: "npu", label: "NPU", hint: "Ryzen AI XDNA 2 • 50+ TOPS" },
];

export const state = {
  online: false,
  active: { gpu: null, npu: null },
  // Static registry from /v1/models, fetched once per page load (see api.fetchModels).
  models: [],
  modelsLoaded: false,
  services: [],
  switching: { gpu: false, npu: false },
  pending: null,
};

export function findModel(name) {
  return state.models.find((model) => model.name === name);
}

export function findService(id) {
  return state.services.find((service) => service.id === id);
}

export function isOnDemand(id) {
  return findService(id)?.type === "on-demand";
}

export function modelDevice(name) {
  return findModel(name)?.device ?? "gpu";
}

export function activeOf(device) {
  return state.active[device] ?? null;
}

export function modelsOfDevice(device) {
  return (state.models || []).filter((model) => (model.device ?? "gpu") === device);
}

// Model the playground should target: the loaded LLM of that domain, else the first
// registered model of that domain.
export function inferenceTarget(device = "gpu") {
  const active = activeOf(device);
  if (active && !isOnDemand(active)) return active;
  return modelsOfDevice(device)[0]?.name ?? "none";
}
