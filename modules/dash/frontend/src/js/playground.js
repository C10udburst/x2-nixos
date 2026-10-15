// Inference playground: streams /v1/chat/completions (SSE) and derives
// prefill speed, decode speed, TTFT and token count.

import { streamChat } from "./api.js";
import { setText } from "./dom.js";
import { inferenceTarget } from "./state.js";

const IDLE_OUTPUT = "Output will stream here…";
const MAX_TOKENS = 1024;

let els = null;
let controller = null;
let generating = false;

export function initPlayground() {
  els = {
    target: document.getElementById("playground-target"),
    prompt: document.getElementById("prompt-input"),
    output: document.getElementById("stream-output"),
    reasoning: document.getElementById("stream-reasoning"),
    content: document.getElementById("stream-content"),
    send: document.getElementById("btn-send"),
    clear: document.getElementById("btn-clear"),
    prefill: document.getElementById("stat-prefill"),
    tps: document.getElementById("stat-tps"),
    ttft: document.getElementById("stat-ttft"),
    tokens: document.getElementById("stat-tokens"),
  };

  els.send.addEventListener("click", () => (generating ? stop() : send()));
  els.clear.addEventListener("click", clear);
}

export function setPlaygroundTarget(target = inferenceTarget()) {
  if (els) setText(els.target, target);
}

// Providers that omit usage stats in streaming mode still need a token estimate.
function estimateTokens(text) {
  if (!text) return 0;
  const parts = text.match(/[\p{L}\p{N}]+|[^\s\p{L}\p{N}]+/gu);
  if (!parts || parts.length === 0) return Math.ceil(text.length / 4) || 1;
  return parts.reduce((total, part) => total + Math.max(1, Math.round(part.length / 3.8)), 0);
}

function resetStats() {
  if (!els) return;
  setText(els.prefill, "--");
  setText(els.tps, "--");
  setText(els.ttft, "--");
  setText(els.tokens, "0");
}

function clear() {
  stop();
  if (!els) return;
  els.reasoning.classList.add("hidden");
  setText(els.reasoning, "");
  setText(els.content, IDLE_OUTPUT);
  els.output.scrollTop = 0;
  resetStats();
}

function stop() {
  controller?.abort();
}

function setGenerating(active) {
  generating = active;
  els.send.textContent = active ? "Stop" : "Generate";
  els.send.classList.toggle("btn-error", active);
  els.send.classList.toggle("btn-primary", !active);
}

function reportDecode(genTokens, firstTokenTime) {
  const seconds = (performance.now() - firstTokenTime) / 1000;
  if (seconds > 0) setText(els.tps, (genTokens / seconds).toFixed(1));
}

function reportPrefill(promptTokens, firstTokenTime, startedAt) {
  const seconds = (firstTokenTime - startedAt) / 1000;
  if (seconds > 0) setText(els.prefill, (promptTokens / seconds).toFixed(1));
}

function appendReasoning(chunk) {
  els.reasoning.classList.remove("hidden");
  els.reasoning.textContent += chunk;
}

async function send() {
  const prompt = els.prompt.value.trim();
  if (!prompt || generating) return;

  resetStats();
  setText(els.prefill, "…");
  setText(els.tps, "…");
  setText(els.ttft, "…");
  els.reasoning.classList.add("hidden");
  setText(els.reasoning, "");
  setText(els.content, "");
  els.output.scrollTop = 0;

  controller = new AbortController();
  setGenerating(true);

  let promptTokens = estimateTokens(prompt);
  let genTokens = 0;
  let firstTokenTime = null;
  let inThinkTag = false;
  const startedAt = performance.now();

  try {
    const res = await streamChat(
      {
        model: inferenceTarget(),
        messages: [{ role: "user", content: prompt }],
        stream: true,
        stream_options: { include_usage: true },
        max_tokens: MAX_TOKENS,
      },
      controller.signal,
    );

    if (!res.ok) {
      setText(els.content, `Error (${res.status}): ${await res.text()}`);
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
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

        const usage = chunk.usage;
        if (usage?.prompt_tokens) {
          promptTokens = usage.prompt_tokens;
          if (firstTokenTime) reportPrefill(promptTokens, firstTokenTime, startedAt);
        }
        if (usage?.completion_tokens) {
          genTokens = usage.completion_tokens;
          setText(els.tokens, String(genTokens));
          if (firstTokenTime) reportDecode(genTokens, firstTokenTime);
        }

        const choice = chunk.choices?.[0];
        const delta = choice?.delta;
        const reasoningChunk = delta?.reasoning_content || delta?.reasoning || delta?.thought || "";
        let contentChunk = delta?.content || delta?.text || choice?.text || "";

        if (reasoningChunk || contentChunk) {
          if (firstTokenTime === null) {
            firstTokenTime = performance.now();
            setText(els.ttft, String(Math.round(firstTokenTime - startedAt)));
            reportPrefill(promptTokens, firstTokenTime, startedAt);
          }
          genTokens += estimateTokens(reasoningChunk + contentChunk);
          setText(els.tokens, String(genTokens));
          if (firstTokenTime < performance.now() - 50) reportDecode(genTokens, firstTokenTime);
        }

        if (reasoningChunk) appendReasoning(reasoningChunk);

        if (contentChunk) {
          if (contentChunk.includes("<think>")) {
            inThinkTag = true;
            const [before, ...rest] = contentChunk.split("<think>");
            if (before) els.content.textContent += before;
            contentChunk = rest.join("<think>");
          }

          if (inThinkTag) {
            if (contentChunk.includes("</think>")) {
              inThinkTag = false;
              const [inside, ...after] = contentChunk.split("</think>");
              appendReasoning(inside);
              const tail = after.join("</think>");
              if (tail) els.content.textContent += tail;
            } else {
              appendReasoning(contentChunk);
            }
          } else {
            els.content.textContent += contentChunk;
          }
        }

        els.output.scrollTop = els.output.scrollHeight;
      }
    }

    if (firstTokenTime && genTokens > 0) reportDecode(genTokens, firstTokenTime);
  } catch (error) {
    if (error.name === "AbortError") {
      if (!els.content.textContent && !els.reasoning.textContent) {
        setText(els.content, "[Generation stopped by user]");
      }
      if (firstTokenTime && genTokens > 0) reportDecode(genTokens, firstTokenTime);
    } else {
      els.content.textContent += `\n[Error: ${error.message}]`;
    }
  } finally {
    if (!firstTokenTime) resetStats();
    controller = null;
    setGenerating(false);
  }
}
