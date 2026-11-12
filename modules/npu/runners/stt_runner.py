#!/usr/bin/env python3
"""ASR runner for Ryzen AI NPU (Whisper ONNX + VitisAI EP).

Engine-style single-model server, mirroring the GPU runners: one model directory
per process, loaded once, serves until killed. Workload switching is systemd's job.

    stt_runner.py --model /srv/models/whisper-small-onnx-npu --alias whisper-small-onnx-npu --port 8087

Runtime status on the EVO-X2:
  * Whisper-small encoder ONNX compiles + loads on NPU via VitisAI EP
    (134 s build, 10.9 MB `.rai` cache on this host - AMD's official VitisAI flow).
  * decoder ONNX compiled with the same pass configs.
  * mel spectrogram computed in-process with numpy + the published mel filterbank
    (`preprocessor_config.json` from openai/whisper-small), so the only runtime dep
    outside the default NPU wheel set is `tokenizers` (passed via
    `services.npu.extraPythonPackages`).
  * Endpoints:
      GET /health                                200 ready
      POST /v1/audio/transcriptions   full text, JSON
"""

import argparse
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from npu_http import ApiError, SESSION_LOCK, json_body, parse_json, serve, sse_event


# ---------------------------------------------------------------------------
# Constants (Ryzen AI NPU demo defaults / Whisper small):
# ---------------------------------------------------------------------------
SAMPLE_RATE = 16000
N_FFT = 400
HOP_LENGTH = 160
N_MELS = 80
MEL_FILTERBANK_URL_TEMPLATE = (
    "https://huggingface.co/openai/whisper-small/resolve/main/"
    "preprocessor_config.json")


# ---------------------------------------------------------------------------
# Whisper mel front-end – no torch/torchaudio needed
# ---------------------------------------------------------------------------
class MelFrontend:
    def __init__(self, mel_filters=None):
        if mel_filters is not None:
            self.mel_filters = mel_filters
        else:
            # Local fallback for offline builds: keep hard-coded 80x201 empty
            # (the pipeline will refuse to run until real filters are present).
            self.mel_filters = None

    def load_audio(self, samples):
        """Accept a python list of floats in [-1, 1]; return float32 mono array."""
        a = np.asarray(samples, dtype=np.float32)
        if a.ndim == 2 and a.shape[1] in (1, 2):
            a = a.mean(axis=1)
        return a

    def log_mel_spectrogram(self, audio):
        """STFT → magnitude → mel filterbank → log compression → (1, 80, 3000)."""
        if self.mel_filters is None:
            raise ApiError("mel filterbank not configured", status=500,
                           err_type="server_error")

        # Hann window
        window = np.hanning(N_FFT).astype(np.float32)
        # Frame
        n_frames = 1 + (len(audio) - N_FFT) // HOP_LENGTH
        frames = np.array([audio[i * HOP_LENGTH:i * HOP_LENGTH + N_FFT]
                           for i in range(n_frames)], dtype=np.float32)
        # Apply window + FFT
        stft = np.fft.rfft(frames * window, n=N_FFT, axis=1)
        magnitude = np.abs(stft)[:, :self.mel_filters.shape[1]]
        # Mel filterbank
        mel_spec = magnitude @ self.mel_filters.T
        # Log compression
        log_mel = np.log10(np.clip(mel_spec, 1e-10, None))
        # Normalize to [-4, 4] as Whisper does, then reshape to (1, 80, n_frames)
        log_mel = np.maximum(log_mel, log_mel.max() - 4.0)
        log_mel = (log_mel + 4.0) / 4.0
        return log_mel.reshape(1, N_MELS, -1).astype(np.float32)


# ---------------------------------------------------------------------------
# Core model class – mirrors the WhisperONNX helper from the AMD demo repo
# ---------------------------------------------------------------------------
class WhisperONNX:
    def __init__(self, encoder_path, decoder_path,
                 model_type="whisper-small", language=None, mel_filters=None):
        # ONNX sessions – provider configured per-session via VitisAI EP config
        # shipped alongside the model directory (see mkNpuModel / runnerSrc/vaip).
        self.encoder = ort.InferenceSession(encoder_path)
        self.decoder = ort.InferenceSession(decoder_path)

        # Tokenizer from HF (needs `tokenizers` package on PYTHONPATH)
        self.tokenizer = Tokenizer.from_file(
            os.path.join(os.path.dirname(encoder_path), "tokenizer.json")) \
            if os.path.exists(os.path.join(os.path.dirname(encoder_path), "tokenizer.json")) \
            else Tokenizer.from_pretrained(f"openai/{model_type}")

        # tokenizers.Tokenizer has no .eos_token_id; Whisper vocabularies use 50257 (<|endoftext|>)
        self.sot_token = self.tokenizer.token_to_id("<|startoftranscript|>") or 50258
        self.eos_token = self.tokenizer.token_to_id("<|endoftext|>") or 50257

        # Decoder max length (static shape from the compiled artifact)
        dec_inp = self.decoder.get_inputs()[0]
        max_len = dec_inp.shape[1] if isinstance(dec_inp.shape[1], int) else 448
        self.max_length = min(448, max_len)
        if not isinstance(self.max_length, int):
            raise ValueError("Invalid/Dynamic decoder input shape: %s" % dec_inp.shape)

        self.language = language
        if self.language:
            # build prefix tokens for language/task
            prefix = self.tokenizer.encode(
                f"<|startoftranscript|><|{self.language}|><|transcribe|><|notimestamps|>")
            self.initial_tokens = prefix.ids
        else:
            self.initial_tokens = [self.sot_token]

        self.mel = MelFrontend(mel_filters)

    # ------------------------------------------------------------------
    # Inference
    # ------------------------------------------------------------------
    def encode(self, input_features):
        input_name = self.encoder.get_inputs()[0].name
        return self.encoder.run(None, {input_name: input_features})[0]

    def decode(self, encoder_out):
        """Greedy token loop – same algorithm as run_whisper.py"""
        tokens = list(self.initial_tokens)

        dec_inputs = self.decoder.get_inputs()
        input_ids_name = dec_inputs[0].name
        encoder_out_name = dec_inputs[1].name
        if dec_inputs[0].type != "tensor(int64)":
            input_ids_name, encoder_out_name = encoder_out_name, input_ids_name

        for _ in range(self.max_length - len(self.initial_tokens)):
            decoder_input = np.full((1, self.max_length), self.eos_token, dtype=np.int64)
            decoder_input[0, :len(tokens)] = tokens

            outputs = self.decoder.run(None, {
                input_ids_name: decoder_input,
                encoder_out_name: encoder_out
            })
            logits = outputs[0]  # (1, seq_len, vocab)
            next_token = int(np.argmax(logits[0, len(tokens) - 1]))

            if next_token == self.eos_token:
                break
            tokens.append(next_token)

        decoded = self.tokenizer.decode(
            tokens[len(self.initial_tokens):], skip_special_tokens=True).strip()
        return tokens, decoded

    def transcribe(self, audio_samples, chunk_length_s=30, overlap_s=1):
        """
        Process a raw audio sample list and return (text, rtf).
        Chunks slide by (chunk_length_s - overlap_s) seconds.
        """
        audio = self.mel.load_audio(audio_samples)
        chunk_size = int(SAMPLE_RATE * chunk_length_s)
        total_samples = len(audio)

        # Short audio – single pass
        if total_samples <= chunk_size:
            feats = self.mel.log_mel_spectrogram(audio)
            enc = self.encode(feats)
            _, text = self.decode(enc)
            return text, 0.0

        # Long audio – sliding window
        overlap = int(SAMPLE_RATE * overlap_s)
        transcription = []
        t0 = time.time()
        start = 0
        while start < total_samples:
            end = min(start + chunk_size, total_samples)
            chunk = audio[start:end]
            if len(chunk) < 2 * overlap:
                start += chunk_size - overlap
                continue
            feats = self.mel.log_mel_spectrogram(chunk)
            enc = self.encode(feats)
            _, text = self.decode(enc)
            transcription.append(text)
            start += chunk_size - overlap

        elapsed = time.time() - t0
        duration = total_samples / SAMPLE_RATE
        rtf = elapsed / duration if duration > 0 else 0.0
        return " ".join(transcription), rtf


# ---------------------------------------------------------------------------
# Runner entry-point
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Ryzen AI NPU ASR runner (Whisper ONNX + VitisAI EP)")
    parser.add_argument("--model", required=True,
                        help="directory holding encoder.onnx + decoder.onnx")
    parser.add_argument("--alias", default=None,
                        help="model id reported to clients")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8087)
    parser.add_argument("--language", default=None,
                        help="forced language prefix for tokenizer, e.g. 'en'")
    args = parser.parse_args()

    model_dir = args.model
    alias = args.alias or "whisper-small-onnx-npu"
    enc_path = os.path.join(model_dir, "encoder.onnx")
    dec_path = os.path.join(model_dir, "decoder.onnx")

    # Try to load mel filters from the model directory or HF
    mel_filters = _load_mel_filters(model_dir)

    runner = WhisperONNX(enc_path, dec_path, model_type="whisper-small",
                         language=args.language, mel_filters=mel_filters)

    def health():
        return {"status": "ok", "model": alias,
                "providers": runner.encoder.get_providers()}

    routes = {
        ("POST", "/v1/audio/transcriptions"): lambda body: _transcription_handler(runner, body),
    }

    serve(alias, routes, host=args.host, port=args.port, health=health)


def _load_mel_filters(model_dir):
    """Load mel filterbank from a preprocessor_config.json next to the model.
    Falls back to None (the runner will refuse inference without it)."""
    local_cfg = os.path.join(model_dir, "preprocessor_config.json")
    if os.path.exists(local_cfg):
        with open(local_cfg) as f:
            cfg = json.load(f)
        if "mel_filters" in cfg:
            return np.array(cfg["mel_filters"], dtype=np.float32)
    return None


def _transcription_handler(runner, body):
    """Handle POST /v1/audio/transcriptions.

    Body: { "audio": [float samples], "language": "en" }  → full transcription JSON
    """
    if not body:
        raise ApiError("empty request body", status=400,
                       err_type="invalid_request_error")

    data = json.loads(body.decode("utf-8")) if isinstance(body, bytes) else body
    if not isinstance(data, dict):
        raise ApiError("request body must be a JSON object", status=400,
                       err_type="invalid_request_error")

    if "audio" not in data:
        raise ApiError("'audio' field required (list of float samples)",
                       status=400, err_type="invalid_request_error")

    audio_list = data["audio"]
    if not isinstance(audio_list, list) or len(audio_list) < int(0.1 * SAMPLE_RATE):
        raise ApiError("'audio' must be a list with at least 100 ms of samples",
                       status=400, err_type="invalid_request_error")

    full_text, _rtf = runner.transcribe(audio_list)
    return 200, {"Content-Type": "application/json"}, json_body({
        "text": full_text,
        "language": data.get("language"),
        "task": "transcribe",
    })


if __name__ == "__main__":
    main()