// Inference playground: streams /v1/chat/completions (SSE) for N parallel agents.
//
// A run fires N concurrent requests at the model picked in the target dropdown. The
// dropdown never calls /api/switch — it only sets the request `model` field, the
// gateway itself hot-swaps whatever the request asks for (Rule 1 stays enforced by
// the switcher). With N > 1 every prompt is prefixed with "You are agent #<n>." so
// the agents do not collapse onto the same completion, one chip per agent toggles
// which panels are shown side by side, and a fleet block averages the metrics.

import { streamChat } from "./api.js";
import { escapeHtml, setExclusiveClass, setText } from "./dom.js";
import { inferenceTarget, state } from "./state.js";

const IDLE_OUTPUT = "Output will stream here…";
const MAX_TOKENS = 1024;
const MAX_AGENTS = 6; // browsers keep at most 6 HTTP/1.1 connections per host

// Full literal class strings so the Tailwind scanner keeps them in the bundle.
const STATS_CLASSES = {
  single: "stats w-full stats-vertical border border-base-300 sm:stats-horizontal",
  multi: "stats w-full stats-vertical border border-base-300",
};
const VALUE_CLASSES = {
  single: "font-mono text-2xl",
  multi: "font-mono text-xl",
};

const CHIP_STATES = ["badge-primary", "badge-ghost"];
const DOT_CLASSES = ["status-neutral", "status-info", "status-warning", "status-success", "status-error"];
const DOT_OF = {
  idle: "status-neutral",
  queued: "status-info",
  running: "status-warning",
  done: "status-success",
  stopped: "status-neutral",
  error: "status-error",
};
const LABEL_OF = {
  idle: "idle",
  queued: "loading model…",
  running: "streaming",
  done: "done",
  stopped: "stopped",
  error: "error",
};

let els = null;
let agents = []; // the agents of the current display (rebuilt on count change / run)
let generating = false;
let pinnedTarget = null; // manual dropdown pick, survives status polling
let targetSignature = "";

/* ------------------------------------------------------------------ helpers */

// Providers that omit usage stats in streaming mode still need a token estimate.
function estimateTokens(text) {
  if (!text) return 0;
  const parts = text.match(/[\p{L}\p{N}]+|[^\s\p{L}\p{N}]+/gu);
  if (!parts || parts.length === 0) return Math.ceil(text.length / 4) || 1;
  return parts.reduce((total, part) => total + Math.max(1, Math.round(part.length / 3.8)), 0);
}

const fixed = (value, digits) => (Number.isFinite(value) ? value.toFixed(digits) : "--");
const mean = (values) => (values.length ? values.reduce((sum, v) => sum + v, 0) / values.length : null);

function makeAgent(index) {
  return {
    index,
    selected: true,
    status: "idle",
    error: "",
    controller: null,
    nodes: null,
    reasoning: "",
    content: IDLE_OUTPUT,
    promptTokens: 0,
    genTokens: 0,
    startedAt: 0,
    firstTokenAt: null,
    ttft: null,
    prefill: null,
    tps: null,
  };
}

function currentCount() {
  const raw = Number.parseInt(els.count.value, 10);
  return Math.min(MAX_AGENTS, Math.max(1, Number.isFinite(raw) ? raw : 1));
}

function selectedModel() {
  return els.target.value || inferenceTarget();
}

// Distinct prompts: agent #n is told who it is, otherwise N identical requests
// against the same seed collapse onto the same completion.
function promptFor(agent, prompt, multi) {
  return multi ? `You are agent #${agent.index}. ${prompt}` : prompt;
}

/* -------------------------------------------------------------------- markup */

function statMarkup(role, title, unit, valueClass) {
  return `
    <div class="stat">
      <div class="stat-title">${title}</div>
      <div class="stat-value ${valueClass}" data-role="${role}">--</div>
      <div class="stat-desc">${unit}</div>
    </div>`;
}

function panelMarkup(agent, multi) {
  const variant = multi ? "multi" : "single";
  return `
    <section class="flex flex-col gap-3 rounded-box border border-base-300 p-3" data-panel="${agent.index}">
      <header class="flex flex-wrap items-center justify-between gap-2 font-mono text-[11px]" data-role="head">
        <span class="font-bold text-primary">agent #${agent.index}</span>
        <span class="flex items-center gap-2 opacity-70">
          <span class="status status-xs status-neutral" data-role="dot"></span>
          <span data-role="state">idle</span>
        </span>
      </header>
      <div class="${STATS_CLASSES[variant]}">
        ${statMarkup("prefill", "Prefill", "tokens / s", VALUE_CLASSES[variant])}
        ${statMarkup("tps", "Inference", "tokens / s", VALUE_CLASSES[variant])}
        ${statMarkup("ttft", "TTFT", "ms to first token", VALUE_CLASSES[variant])}
        ${statMarkup("tokens", "Tokens", "generated", VALUE_CLASSES[variant])}
      </div>
      <div data-role="scroll" class="min-h-20 max-h-96 overflow-y-auto rounded-box bg-base-300 p-4 font-mono text-xs">
        <div data-role="reasoning" class="hidden mb-3 whitespace-pre-wrap border-l-2 border-warning p-3 opacity-80"></div>
        <div data-role="content" class="whitespace-pre-wrap opacity-80"></div>
      </div>
    </section>`;
}

function chipMarkup(agent) {
  return `
    <button type="button" class="badge badge-ghost badge-sm cursor-pointer gap-1.5 border font-mono"
            data-chip="${agent.index}" aria-pressed="true"
            title="Toggle agent #${agent.index} panel">
      <span class="status status-xs status-neutral" data-role="chip-dot"></span>
      <span class="font-bold">#${agent.index}</span>
      <span class="opacity-70" data-role="chip-meta">idle</span>
    </button>`;
}

/* --------------------------------------------------------------- rendering */

function bindNodes(agent) {
  const panel = els.panels.querySelector(`[data-panel="${agent.index}"]`);
  const chip = els.chips.querySelector(`[data-chip="${agent.index}"]`);
  const node = (role, root = panel) => root?.querySelector(`[data-role="${role}"]`) ?? null;
  agent.nodes = {
    panel,
    head: node("head"),
    dot: node("dot"),
    state: node("state"),
    prefill: node("prefill"),
    tps: node("tps"),
    ttft: node("ttft"),
    tokens: node("tokens"),
    scroll: node("scroll"),
    reasoning: node("reasoning"),
    content: node("content"),
    chip,
    chipDot: node("chip-dot", chip),
    chipMeta: node("chip-meta", chip),
  };
}

// Rebuild chips + panels for `count` agents and reset every metric/output.
function rebuild(count) {
  const multi = count > 1;
  agents = Array.from({ length: count }, (_, i) => makeAgent(i + 1));

  els.chips.innerHTML =
    agents.map(chipMarkup).join("") +
    (count > 2 ? '<button type="button" class="badge badge-ghost badge-sm cursor-pointer border font-mono" data-chip-all>select all</button>' : "");
  els.panels.innerHTML = agents.map((agent) => panelMarkup(agent, multi)).join("");
  for (const agent of agents) bindNodes(agent);

  syncLayout();
  patchFleet();
}

// Visibility of chips / averages, grid columns and per-panel hidden state.
function syncLayout() {
  const multi = agents.length > 1;
  els.chips.classList.toggle("hidden", !multi);
  els.avg.classList.toggle("hidden", !multi);

  const visible = agents.filter((agent) => agent.selected).length || 1;
  els.panels.classList.toggle("md:grid-cols-2", multi);
  els.panels.classList.toggle("xl:grid-cols-3", multi && visible >= 3);

  for (const agent of agents) {
    const nodes = agent.nodes;
    if (!nodes) continue;
    nodes.panel.classList.toggle("hidden", !agent.selected);
    nodes.head.classList.toggle("hidden", !multi);
    if (nodes.chip) {
      setExclusiveClass(nodes.chip, agent.selected ? "badge-primary" : "badge-ghost", CHIP_STATES);
      nodes.chip.setAttribute("aria-pressed", String(agent.selected));
    }
  }

  setText(
    els.hint,
    multi
      ? `${agents.length} agents • "You are agent #N." prepended to each prompt`
      : "POST /v1/chat/completions • SSE",
  );
}

function patchAgent(agent) {
  const nodes = agent.nodes;
  if (!nodes) return;

  setText(nodes.prefill, fixed(agent.prefill, 1));
  setText(nodes.tps, fixed(agent.tps, 1));
  setText(nodes.ttft, agent.ttft === null ? "--" : String(agent.ttft));
  setText(nodes.tokens, String(agent.genTokens));
  setText(nodes.state, LABEL_OF[agent.status]);
  setText(nodes.content, agent.status === "error" ? agent.error : agent.content);
  setText(nodes.reasoning, agent.reasoning);
  nodes.reasoning?.classList.toggle("hidden", agent.reasoning.length === 0);

  setExclusiveClass(nodes.dot, DOT_OF[agent.status], DOT_CLASSES);
  nodes.dot?.classList.toggle("animate-pulse", agent.status === "running");

  if (nodes.chip) {
    setExclusiveClass(nodes.chipDot, DOT_OF[agent.status], DOT_CLASSES);
    nodes.chipDot?.classList.toggle("animate-pulse", agent.status === "running");
    const seconds = agent.firstTokenAt ? Math.round((performance.now() - agent.startedAt) / 1000) : 0;
    const meta =
      agent.genTokens === 0
        ? LABEL_OF[agent.status]
        : `${agent.genTokens} tk${agent.status === "running" && seconds ? ` • ${seconds}s` : ""}`;
    setText(nodes.chipMeta, meta);
  }
}

function patchFleet() {
  if (agents.length < 2) return;
  const streamed = agents.filter((agent) => agent.firstTokenAt !== null);
  const done = agents.filter((agent) => ["done", "stopped", "error"].includes(agent.status)).length;

  setText(els.avgPrefill, fixed(mean(streamed.map((a) => a.prefill).filter(Number.isFinite)), 1));
  setText(els.avgTps, fixed(mean(agents.map((a) => a.tps).filter(Number.isFinite)), 1));
  setText(els.avgTtft, fixed(mean(streamed.map((a) => a.ttft).filter(Number.isFinite)), 0));
  setText(els.avgTokens, fixed(mean(agents.map((a) => a.genTokens)), 0));
  setText(els.sumTokens, String(agents.reduce((sum, a) => sum + a.genTokens, 0)));
  setText(els.avgProgress, `${done}/${agents.length} done`);
}

function scrollPanel(agent) {
  const { scroll, panel } = agent.nodes ?? {};
  if (scroll && panel && !panel.classList.contains("hidden")) scroll.scrollTop = scroll.scrollHeight;
}

/* ------------------------------------------------------------------ streaming */

function appendReasoning(agent, chunk) {
  agent.reasoning += chunk;
}

function appendContent(agent, chunk) {
  agent.content += chunk;
}

// Re-derive the agent metrics from the tokens seen so far.
function refreshMetrics(agent) {
  const now = performance.now();
  const prefillSeconds = (agent.firstTokenAt - agent.startedAt) / 1000;
  if (prefillSeconds > 0) agent.prefill = agent.promptTokens / prefillSeconds;
  const decodeSeconds = (now - agent.firstTokenAt) / 1000;
  if (decodeSeconds > 0) agent.tps = agent.genTokens / decodeSeconds;
}

function handleChunk(agent, chunk, thinkState) {
  const usage = chunk.usage;
  if (usage?.prompt_tokens) agent.promptTokens = usage.prompt_tokens;
  if (usage?.completion_tokens) agent.genTokens = usage.completion_tokens;

  const choice = chunk.choices?.[0];
  const delta = choice?.delta;
  const reasoningChunk = delta?.reasoning_content || delta?.reasoning || delta?.thought || "";
  let contentChunk = delta?.content || delta?.text || choice?.text || "";
  if (!reasoningChunk && !contentChunk) return;

  if (agent.firstTokenAt === null) {
    agent.firstTokenAt = performance.now();
    agent.ttft = Math.round(agent.firstTokenAt - agent.startedAt);
  }

  agent.genTokens += estimateTokens(reasoningChunk + contentChunk);
  refreshMetrics(agent);

  if (reasoningChunk) appendReasoning(agent, reasoningChunk);

  if (contentChunk) {
    if (contentChunk.includes("<think>")) {
      thinkState.inThinkTag = true;
      const [before, ...rest] = contentChunk.split("<think>");
      if (before) appendContent(agent, before);
      contentChunk = rest.join("<think>");
    }

    if (thinkState.inThinkTag) {
      if (contentChunk.includes("</think>")) {
        thinkState.inThinkTag = false;
        const [inside, ...after] = contentChunk.split("</think>");
        appendReasoning(agent, inside);
        const tail = after.join("</think>");
        if (tail) appendContent(agent, tail);
      } else {
        appendReasoning(agent, contentChunk);
      }
    } else {
      appendContent(agent, contentChunk);
    }
  }
}

async function runAgent(agent, prompt, model) {
  agent.controller = new AbortController();
  agent.content = "";
  agent.reasoning = "";
  agent.promptTokens = estimateTokens(prompt);
  agent.startedAt = performance.now();
  agent.status = "queued";
  patchAgent(agent);
  patchFleet();

  try {
    const res = await streamChat(
      {
        model,
        messages: [{ role: "user", content: prompt }],
        stream: true,
        stream_options: { include_usage: true },
        max_tokens: MAX_TOKENS,
      },
      agent.controller.signal,
    );

    agent.status = "running";
    patchAgent(agent);

    if (!res.ok) {
      agent.error = `Error (${res.status}): ${await res.text()}`;
      agent.status = "error";
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    const thinkState = { inThinkTag: false };
    let buffer = "";

    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop();

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data: ")) continue;
        const payload = trimmed.slice(6).trim();
        if (payload === "[DONE]") continue;

        let chunk;
        try {
          chunk = JSON.parse(payload);
        } catch {
          continue;
        }
        handleChunk(agent, chunk, thinkState);
      }

      patchAgent(agent);
      patchFleet();
      scrollPanel(agent);
    }
  } catch (error) {
    if (error.name === "AbortError") {
      agent.status = "stopped";
    } else {
      agent.error = `[Error: ${error.message}]`;
      agent.status = "error";
    }
  } finally {
    if (agent.firstTokenAt) refreshMetrics(agent);
    if (agent.status === "running") agent.status = "done";
    if (!agent.content && !agent.reasoning && agent.status !== "error") {
      agent.content =
        agent.status === "stopped" ? "[Generation stopped by user]" : "[No tokens received]";
    }
    agent.controller = null;
    patchAgent(agent);
    patchFleet();
  }
}

/* ---------------------------------------------------------------- entry points */

async function send() {
  const prompt = els.prompt.value.trim();
  const model = selectedModel();
  if (!prompt || !model || generating) return;

  const count = currentCount();
  els.count.value = String(count);
  rebuild(count);

  const multi = count > 1;
  generating = true;
  setGenerating(true);

  await Promise.all(agents.map((agent) => runAgent(agent, promptFor(agent, prompt, multi), model)));

  generating = false;
  setGenerating(false);
  patchFleet();
}

function stop() {
  for (const agent of agents) agent.controller?.abort();
}

function clear() {
  stop();
  rebuild(currentCount());
}

function setGenerating(active) {
  els.send.textContent = active ? "Stop" : "Generate";
  els.send.classList.toggle("btn-error", active);
  els.send.classList.toggle("btn-primary", !active);
  els.count.disabled = active;
  els.target.disabled = active;
}

/* ---------------------------------------------------------------- target select */

function renderTargetOptions() {
  const names = (state.models ?? []).map((model) => model.name);
  const signature = `${names.join("|")}@${state.active ?? ""}`;
  if (signature === targetSignature) return;
  targetSignature = signature;

  const previous = els.target.value;
  els.target.innerHTML = names.length
    ? names
        .map(
          (name) =>
            `<option value="${escapeHtml(name)}">${escapeHtml(name)}${
              name === state.active ? " • loaded" : ""
            }</option>`,
        )
        .join("")
    : '<option value="">no models registered</option>';
  els.target.disabled = names.length === 0;
  if (names.includes(previous)) els.target.value = previous;
}

export function setPlaygroundTarget(target = inferenceTarget()) {
  if (!els) return;
  renderTargetOptions();
  if (generating) return; // never fight the user (or a live run) mid-stream

  const options = [...els.target.options].map((option) => option.value);
  if (pinnedTarget && options.includes(pinnedTarget)) {
    els.target.value = pinnedTarget;
    return;
  }
  pinnedTarget = null;
  if (options.includes(target)) els.target.value = target;
}

// An explicit workload switch elsewhere on the page owns the target again.
export function clearPlaygroundTargetPick() {
  pinnedTarget = null;
}

export function initPlayground() {
  els = {
    target: document.getElementById("playground-target"),
    count: document.getElementById("agent-count"),
    prompt: document.getElementById("prompt-input"),
    send: document.getElementById("btn-send"),
    clear: document.getElementById("btn-clear"),
    hint: document.getElementById("agent-hint"),
    chips: document.getElementById("agent-chips"),
    panels: document.getElementById("agent-panels"),
    avg: document.getElementById("agent-avg"),
    avgPrefill: document.getElementById("avg-prefill"),
    avgTps: document.getElementById("avg-tps"),
    avgTtft: document.getElementById("avg-ttft"),
    avgTokens: document.getElementById("avg-tokens"),
    sumTokens: document.getElementById("sum-tokens"),
    avgProgress: document.getElementById("avg-progress"),
  };

  els.count.min = "1";
  els.count.max = String(MAX_AGENTS);
  els.count.value = "1";

  els.send.addEventListener("click", () => (generating ? stop() : send()));
  els.clear.addEventListener("click", clear);
  els.count.addEventListener("change", () => {
    if (generating) return;
    els.count.value = String(currentCount());
    rebuild(Number(els.count.value));
  });
  els.target.addEventListener("change", () => {
    pinnedTarget = els.target.value;
  });
  els.chips.addEventListener("click", (event) => {
    if (event.target.closest("[data-chip-all]")) {
      for (const agent of agents) agent.selected = true;
      syncLayout();
      return;
    }
    const chip = event.target.closest("[data-chip]");
    if (!chip) return;
    const agent = agents.find((candidate) => candidate.index === Number(chip.dataset.chip));
    if (!agent) return;
    if (agent.selected && agents.filter((candidate) => candidate.selected).length === 1) {
      for (const other of agents) other.selected = true; // never hide every panel
    } else {
      agent.selected = !agent.selected;
    }
    syncLayout();
  });

  rebuild(1);
}
