#!/usr/bin/env python3
"""Embeddings runner for Ryzen AI NPU (ONNX Runtime + VitisAI execution provider).

Engine-style single-model server, mirroring the GPU runners: one model directory per
process, loaded once, serves until killed. Workload switching is systemd's job.

    embeddings_runner.py --model /srv/models/embeddinggemma-300m --alias embeddinggemma-300m --port 8085

Runtime status on the EVO-X2 (full recipe in ../README.md):
  * Verified working: onnxruntime 1.30.0 (`onnxruntime_vitisai` wheel) reports
    ['VitisAIExecutionProvider', 'CPUExecutionProvider'] and the EP compiles + runs a
    model on /dev/accel/accel0 (AMD's quicktest CNN finishes in ~4 s).
  * NOT runnable yet: AMD's only published NPU embedding artifact,
    amd/embeddinggemma-300m_npu_rai_1.8.0_npu_4K, references a custom op
    (`com.ryzenai:CastAvx`) that no Ryzen AI 1.8/1.9 runtime registers, so session
    creation fails - https://github.com/amd/RyzenAI-SW/issues/387. This runner exists so
    enabling embeddings later is a model download, not a code change.

Endpoint: POST /v1/embeddings.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from npu_http import ApiError, SESSION_LOCK, json_body, parse_json, serve  # noqa: E402


class EmbeddingsRunner:
    def __init__(self, model_dir, alias):
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.np = np
        self.model_dir = model_dir
        self.alias = alias

        onnx_path = os.path.join(model_dir, "model.onnx")
        if not os.path.exists(onnx_path):
            raise ApiError(f"{onnx_path} not found", 500, "server_error")

        tokenizer_path = os.path.join(model_dir, "tokenizer.json")
        if not os.path.exists(tokenizer_path):
            # AMD publishes compiled artifacts only, so the tokenizer sidecar has to be
            # placed next to them when the weights are installed.
            raise ApiError(
                f"{tokenizer_path} is missing - the compiled artifact ships without "
                "tokenizer files; place tokenizer.json next to model.onnx",
                500,
                "server_error",
            )

        self.tokenizer = Tokenizer.from_file(tokenizer_path)
        self.max_seq = int(os.environ.get("NPU_MAX_SEQ", "2048"))
        try:
            self.tokenizer.enable_truncation(max_length=self.max_seq)
        except Exception:
            pass

        cache_dir = os.environ.get("NPU_CACHE_DIR") or os.path.join(
            os.environ.get("TMPDIR", "/tmp"), "npu-cache"
        )
        os.makedirs(cache_dir, exist_ok=True)

        # Provider option sets are tried in order: the VitisAI EP wants a writable
        # cache_dir for its compile plan, but builds differ per artifact.
        attempts = [
            {"cache_dir": cache_dir, "load_config_file": False},
            {"cache_dir": cache_dir},
            {},
        ]
        failures = []
        self.session = None
        for options in attempts:
            session_options = ort.SessionOptions()
            session_options.log_severity_level = 2
            try:
                self.session = ort.InferenceSession(
                    onnx_path,
                    sess_options=session_options,
                    providers=["VitisAIExecutionProvider", "CPUExecutionProvider"],
                    provider_options=[options, {}],
                )
                self.provider_options = options
                break
            except Exception as exc:
                failures.append(f"{options}: {str(exc)[:300]}")
        if self.session is None:
            raise ApiError("could not create an NPU session: " + " | ".join(failures)[:1200])

        self.input_names = {item.name for item in self.session.get_inputs()}
        self.output_names = [item.name for item in self.session.get_outputs()]
        if "input_ids" not in self.input_names:
            raise ApiError(
                f"unexpected model inputs {sorted(self.input_names)}; this runner feeds "
                "input_ids/attention_mask (+ position_ids when present)",
                500,
                "server_error",
            )

    # ------------------------------------------------------------------------ internals
    def encode(self, text):
        np = self.np
        encoding = self.tokenizer.encode(text)
        ids = np.asarray([encoding.ids], dtype=np.int64)
        mask = np.asarray([encoding.attention_mask], dtype=np.int64)
        feeds = {"input_ids": ids, "attention_mask": mask}
        if "position_ids" in self.input_names:
            feeds["position_ids"] = np.arange(ids.shape[1], dtype=np.int64).reshape(1, -1)
        return {k: v for k, v in feeds.items() if k in self.input_names}, len(encoding.ids)

    def pool(self, output, mask):
        """Mean-pool token states over the mask then L2-normalize (EmbeddingGemma recipe).

        A rank-2 output is already sentence-level, so it is only normalized.
        """
        np = self.np
        vec = np.asarray(output).astype(np.float32)
        if vec.ndim == 3:
            weights = np.asarray(mask, dtype=np.float32)[..., None]
            vec = (vec * weights).sum(axis=1) / np.maximum(weights.sum(axis=1), 1.0)
        elif vec.ndim > 3:
            vec = vec.reshape(vec.shape[0], -1)
        norm = float(np.linalg.norm(vec))
        if norm > 0:
            vec = vec / norm
        return vec.reshape(-1)

    # ---------------------------------------------------------------------------- route
    def embeddings(self, body):
        data = parse_json(body)
        raw = data.get("input")
        if raw is None:
            raise ApiError("'input' is required")
        if isinstance(raw, str):
            texts = [raw]
        elif isinstance(raw, list) and all(isinstance(item, str) for item in raw) and raw:
            texts = raw
        else:
            raise ApiError("'input' must be a non-empty string or list of strings")
        if data.get("encoding_format", "float") != "float":
            raise ApiError("only encoding_format='float' is supported")

        vectors = []
        prompt_tokens = 0
        with SESSION_LOCK:
            for text in texts:
                feeds, tokens = self.encode(text)
                prompt_tokens += tokens
                output = self.session.run(None, feeds)[0]
                vectors.append(self.pool(output, feeds.get("attention_mask")))

        payload = {
            "object": "list",
            "data": [
                {"object": "embedding", "index": index, "embedding": [float(x) for x in vector]}
                for index, vector in enumerate(vectors)
            ],
            "model": data.get("model") or self.alias,
            "usage": {"prompt_tokens": prompt_tokens, "total_tokens": prompt_tokens},
        }
        return 200, {"Content-Type": "application/json"}, json_body(payload)

    def health(self):
        return {
            "engine": "onnxruntime + VitisAI EP (Ryzen AI)",
            "provider": (self.session.get_providers() or ["?"])[0],
            "model_dir": self.model_dir,
            "inputs": sorted(self.input_names),
            "outputs": self.output_names,
            "max_seq": self.max_seq,
        }


def main():
    parser = argparse.ArgumentParser(description="Ryzen AI NPU embeddings runner (one model per process)")
    parser.add_argument("--model", required=True, help="directory holding model.onnx (+ tokenizer.json)")
    parser.add_argument("--alias", default=None)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8085)
    args = parser.parse_args()

    if not os.path.isdir(args.model):
        sys.stderr.write(f"[npu] model directory {args.model} does not exist\n")
        return 2

    alias = args.alias or os.path.basename(os.path.normpath(args.model))
    runner = EmbeddingsRunner(args.model, alias)
    serve(alias, {("POST", "/v1/embeddings"): runner.embeddings}, host=args.host, port=args.port,
          health=runner.health)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
