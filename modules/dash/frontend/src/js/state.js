// Shared client state for the dashboard.

export const POLL_INTERVAL_MS = 2500;

export const state = {
  online: false,
  active: null,
  models: [],
  services: [],
  switching: false,
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

// Model the playground should target: the loaded LLM, or the first registered model.
export function inferenceTarget() {
  if (state.active && !isOnDemand(state.active)) return state.active;
  return state.models[0]?.name ?? "none";
}
