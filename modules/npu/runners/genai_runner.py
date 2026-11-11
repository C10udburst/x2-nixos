#!/usr/bin/env python3
"""Chat/completions runner for Ryzen AI NPU genai (OGA) models.

Engine-style single-model server, mirroring the GPU runners: it loads one model
directory, serves until killed, and workload switching is done by systemd under
/run/model-lock/npu.lock by the gateway switcher.

    genai_runner.py --model /srv/models/llama-3.2-1b-npu --alias llama-3.2-1b-npu --port 8083

Verified on the EVO-X2 with Ryzen AI 1.9.0 (see ../README.md for the full runtime recipe):
  * `import onnxruntime_genai` (wheel onnxruntime_genai_ryzenai-0.18.0) works with
    XILINX_XRT + LD_LIBRARY_PATH + RYZENAI_EP_PATH exported by the launcher.
  * Blocked upstream: og.Model() aborts with
        DRM_IOCTL_AMDXDNA_CREATE_BO IOCTL failed (err=-14): Bad address
    + dmesg `amdxdna_get_ubuf: Failed to pin pages ret -14`, on both the small
    Qwen2.5-0.5B and the Llama-3.2-1B _rai_1.9.0_npu artifacts. The in-kernel amdxdna
    driver works (the VitisAI EP compiles and runs a CNN on the NPU), but AMD's own
    out-of-tree amdxdna (shipped as DKMS source inside xrt_plugin.*-amdxdna.deb, which is
    what their Ubuntu install uses) is what the genai/dynamic-dispatch path expects.
    Everything below is written against the OGA 0.18 Python API and is ready to run the
    moment the driver half of the stack matches; only the load step is exercised so far.

Endpoints: POST /v1/chat/completions (stream + non-stream), POST /v1/completions.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from npu_http import ApiError, SESSION_LOCK, json_body, parse_json, serve, sse_event  # noqa: E402


class ChatRunner:
    def __init__(self, model_dir, alias):
        import onnxruntime_genai as og

        self.og = og
        self.model_dir = model_dir
        self.alias = alias

        config_path = os.path.join(model_dir, "genai_config.json")
        with open(config_path, "r", encoding="utf-8") as handle:
            config = json.load(handle)
        model_cfg = config.get("model", {})
        search = config.get("search", {})
        self.context_length = int(model_cfg.get("context_length", 8192))

        # Defaults come from the model's own genai_config.json - never duplicated in Nix.
        self.defaults = {
            "do_sample": bool(search.get("do_sample", True)),
            "temperature": float(search.get("temperature", 1.0)),
            "top_p": float(search.get("top_p", 1.0)),
            "top_k": int(search.get("top_k", 50)),
        }
        # Requested generation cap; the config's max_length is the whole context window.
        self.max_new_tokens = int(os.environ.get("NPU_MAX_NEW_TOKENS", "512"))

        self.model = og.Model(model_dir)
        self.tokenizer = og.Tokenizer(self.model)
        # Incremental decoder class; a fresh instance is created per run (see _decoder).
        self.stream_cls = og.TokenizerStream if hasattr(og, "TokenizerStream") else None

    # ------------------------------------------------------------------ chat template
    def render(self, messages, add_generation_prompt=True):
        """Prefer the engine's own template handling (it knows the tokenizer's specials).

        Ryzen AI 1.9.0's binding takes the conversation as a JSON string
        (`apply_chat_template(messages: str, *, template_str, tools,
        add_generation_prompt)`); older onnxruntime-genai builds take a Python list. Try
        the JSON form first, then the list, then render chat_template.jinja ourselves.
        """
        for payload in (json.dumps(messages), messages):
            try:
                rendered = self.tokenizer.apply_chat_template(
                    payload, add_generation_prompt=add_generation_prompt
                )
            except TypeError:
                continue
            except Exception as exc:
                raise ApiError(f"apply_chat_template failed: {exc}", 500, "server_error")
            if rendered is not None:
                return rendered

        # Fallback: render the repo's chat_template.jinja ourselves.
        template_path = os.path.join(self.model_dir, "chat_template.jinja")
        if not os.path.exists(template_path):
            raise ApiError(
                "the engine could not apply a chat template and the model ships no "
                "chat_template.jinja",
                501,
                "server_error",
            )
        try:
            import jinja2
        except ImportError as exc:
            raise ApiError(f"jinja2 is required for the template fallback: {exc}", 500, "server_error")

        meta = {}
        try:
            with open(os.path.join(self.model_dir, "tokenizer_config.json"), encoding="utf-8") as fh:
                meta = json.load(fh)
        except Exception:
            meta = {}
        with open(template_path, encoding="utf-8") as fh:
            template = jinja2.Environment(keep_trailing_newline=True).from_string(fh.read())
        return template.render(
            messages=messages,
            add_generation_prompt=add_generation_prompt,
            tools=meta.get("tools"),
            bos_token="<s>",
            eos_token="</s>",
            strftime_now=lambda fmt: time.strftime(fmt),
        )

    # ------------------------------------------------------------------- search options
    def search_options(self, data):
        """OpenAI sampling fields -> OGA search options.

        Only the sampling knobs live here. OGA 0.18 has no `max_new_tokens`; its
        `max_length` is the whole window, so the completion cap is turned into a per-request
        `max_length = len(prompt) + cap` in `_generator()`.
        """
        requested = data.get("max_tokens") or data.get("max_new_tokens") or self.max_new_tokens
        try:
            new_cap = max(1, min(int(requested), self.max_new_tokens))
        except (TypeError, ValueError):
            raise ApiError("max_tokens must be an integer")

        do_sample = bool(data.get("do_sample", self.defaults["do_sample"]))
        options = {}
        if do_sample:
            options["temperature"] = float(data.get("temperature", self.defaults["temperature"]))
            options["top_p"] = float(data.get("top_p", self.defaults["top_p"]))
            options["top_k"] = int(data.get("top_k", self.defaults["top_k"]))
        return options, new_cap

    @staticmethod
    def messages_of(data):
        messages = data.get("messages")
        if not isinstance(messages, list) or not messages:
            raise ApiError("'messages' must be a non-empty list")
        normalised = []
        for message in messages:
            if not isinstance(message, dict) or "role" not in message:
                raise ApiError("every message needs a 'role'")
            content = message.get("content", "")
            if isinstance(content, list):  # OpenAI content-part arrays
                content = "".join(
                    part.get("text", "") for part in content if isinstance(part, dict)
                )
            normalised.append({"role": str(message["role"]), "content": str(content)})
        return normalised

    # ------------------------------------------------------------------------ routes
    def chat_completions(self, body):
        data = parse_json(body)
        messages = self.messages_of(data)
        options, cap = self.search_options(data)
        prompt = self.render(messages)
        streaming = bool(data.get("stream", False))

        if streaming:
            return 200, {"Content-Type": "text/event-stream"}, self._stream(data, prompt, options, cap)
        return 200, {"Content-Type": "application/json"}, self._complete(data, prompt, options, cap)

    def completions(self, body):
        data = parse_json(body)
        prompt_text = data.get("prompt")
        if isinstance(prompt_text, list):
            prompt_text = "".join(str(part) for part in prompt_text)
        if not isinstance(prompt_text, str) or not prompt_text:
            raise ApiError("'prompt' must be a non-empty string")
        options, cap = self.search_options(data)

        if bool(data.get("stream", False)):
            return (
                200,
                {"Content-Type": "text/event-stream"},
                self._stream(data, prompt_text, options, cap, completions=True),
            )
        return (
            200,
            {"Content-Type": "application/json"},
            self._complete(data, prompt_text, options, cap, completions=True),
        )

    # --------------------------------------------------------------- generation cores
    def _generator(self, prompt, options, cap):
        """Seed a generation session and return (generator, prompt_tokens).

        OGA 0.18 dropped the `params.input_ids` attribute: the sequence is seeded with
        `Generator.append_tokens()`, and the window has to include the prompt because
        `max_length` counts prompt + generation together.
        """
        ids = self.tokenizer.encode(prompt)
        params = self.og.GeneratorParams(self.model)
        params.set_search_options(
            **{**options, "max_length": min(self.context_length, len(ids) + cap)}
        )
        gen = self.og.Generator(self.model, params)
        gen.append_tokens(ids)
        return gen, len(ids)

    def _decoder(self):
        """A fresh TokenizerStream per run: it accumulates state, so sharing one between
        requests would leak the previous sequence into the next one."""
        if self.stream_cls is not None:
            try:
                return self.stream_cls(self.model)
            except Exception:
                return None
        return None

    def _decode(self, decoder, indices):
        if decoder is not None:
            return decoder.decode(indices)
        return self.tokenizer.decode(indices)

    def _decode_sequence(self, gen, prompt_tokens):
        """Decode the finished sequence in a single call.

        Streaming needs the incremental decoder, but for a complete answer decoding token by
        token splits multi-byte UTF-8 characters and leaves U+FFFD at the end - so the
        non-streaming path decodes the whole new-suffix once.
        """
        try:
            sequence = list(gen.get_sequence(0))
        except Exception:
            return ""
        return self.tokenizer.decode(sequence[prompt_tokens:])

    def _complete(self, data, prompt, options, cap, completions=False):
        created = int(time.time())
        model = data.get("model") or self.alias
        limit = cap + 1  # safety net; the engine enforces the max_length window itself
        new_tokens = 0
        prompt_tokens = 0

        with SESSION_LOCK:
            gen, prompt_tokens = self._generator(prompt, options, cap)
            while not gen.is_done() and new_tokens < limit:
                gen.generate_next_token()
                new_tokens += 1
            text = self._decode_sequence(gen, prompt_tokens)
            stopped = new_tokens < limit  # loop ended because the engine reported is_done()

        text = text.replace("</s>", "").rstrip()
        finish = "stop" if stopped else "length"

        if completions:
            payload = {
                "id": f"cmpl-{created}",
                "object": "text_completion",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "text": text, "finish_reason": finish}],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": new_tokens,
                    "total_tokens": prompt_tokens + new_tokens,
                },
            }
        else:
            payload = {
                "id": f"chatcmpl-{created}",
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": text},
                        "finish_reason": finish,
                    }
                ],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": new_tokens,
                    "total_tokens": prompt_tokens + new_tokens,
                },
            }
        return json_body(payload)

    def _stream(self, data, prompt, options, cap, completions=False):
        """Yield SSE chunks. The lock is held for the whole stream: one session, one run."""
        created = int(time.time())
        model = data.get("model") or self.alias
        cid = f"{'cmpl' if completions else 'chatcmpl'}-{created}"
        limit = cap + 1

        def generate():
            base = {
                "id": cid,
                "object": "text_completion" if completions else "chat.completion.chunk",
                "created": created,
                "model": model,
            }
            first_delta = {"role": "assistant", "content": ""} if not completions else {"content": ""}
            yield sse_event({**base, "choices": [{"index": 0, "delta": first_delta, "finish_reason": None}]})
            emitted = 0
            with SESSION_LOCK:
                decoder = self._decoder()
                gen, _ = self._generator(prompt, options, cap)
                while not gen.is_done() and emitted < limit:
                    gen.generate_next_token()
                    emitted += 1
                    try:
                        piece = self._decode(decoder, gen.get_next_tokens())
                    except Exception:
                        break
                    if piece:
                        delta = {"text": piece} if completions else {"content": piece}
                        yield sse_event({**base, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
                stopped = bool(gen.is_done()) if hasattr(gen, "is_done") else False
            finish = "stop" if stopped else "length"
            final_delta = {} if completions else {"content": ""}
            yield sse_event(
                {
                    **base,
                    "choices": [{"index": 0, "delta": final_delta, "finish_reason": finish}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": emitted, "total_tokens": emitted},
                }
            )
            yield b"data: [DONE]\n\n"

        return generate()

    def health(self):
        return {
            "engine": "onnxruntime-genai (Ryzen AI)",
            "model_dir": self.model_dir,
            "context_length": self.context_length,
            "max_new_tokens": self.max_new_tokens,
            "defaults": self.defaults,
        }


def main():
    parser = argparse.ArgumentParser(description="Ryzen AI NPU chat runner (one model per process)")
    parser.add_argument("--model", required=True, help="directory holding genai_config.json + weights")
    parser.add_argument("--alias", default=None, help="model id reported to clients")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8083)
    args = parser.parse_args()

    if not os.path.isdir(args.model):
        sys.stderr.write(f"[npu] model directory {args.model} does not exist\n")
        return 2

    alias = args.alias or os.path.basename(os.path.normpath(args.model))
    runner = ChatRunner(args.model, alias)
    routes = {
        ("POST", "/v1/chat/completions"): runner.chat_completions,
        ("POST", "/v1/completions"): runner.completions,
    }
    serve(alias, routes, host=args.host, port=args.port, health=runner.health)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
