#!/usr/bin/env bash
#
# Start the local labeling model server (llama.cpp) on Apple Silicon.
#
# The model is ALREADY downloaded to ./models (pulled via the China mirror
# hf-mirror.com because huggingface.co is blocked in this environment):
#   - models/SmolVLM2-2.2B-Instruct-Q4_K_M.gguf      (main, ~1.11GB, INT4)
#   - models/mmproj-SmolVLM2-2.2B-Instruct-Q8_0.gguf  (multimodal projector)
#
# This serves an OpenAI-compatible API at http://127.0.0.1:8080/v1, which
# tools/auto_label.py talks to. After it prints "server is listening", run:
#   python3 tools/auto_label.py data/raw_clips --out data/labels/labels.csv
#
# To re-download the models (if missing), use the mirror:
#   curl -L "https://hf-mirror.com/ggml-org/SmolVLM2-2.2B-Instruct-GGUF/resolve/main/SmolVLM2-2.2B-Instruct-Q4_K_M.gguf"  -o models/SmolVLM2-2.2B-Instruct-Q4_K_M.gguf
#   curl -L "https://hf-mirror.com/ggml-org/SmolVLM2-2.2B-Instruct-GGUF/resolve/main/mmproj-SmolVLM2-2.2B-Instruct-Q8_0.gguf" -o models/mmproj-SmolVLM2-2.2B-Instruct-Q8_0.gguf
#
set -e

cd "$(dirname "$0")/.."   # project root

MODEL="models/SmolVLM2-2.2B-Instruct-Q4_K_M.gguf"
MMPROJ="models/mmproj-SmolVLM2-2.2B-Instruct-Q8_0.gguf"

BIN="llama-server"
if ! command -v "$BIN" >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/llama-server ]; then
    BIN="/opt/homebrew/bin/llama-server"
  else
    echo "ERROR: llama-server not found. Install with: brew install llama.cpp" >&2
    exit 1
  fi
fi

if [ ! -f "$MODEL" ]; then
  echo "ERROR: $MODEL missing. Re-download via hf-mirror.com (see header)." >&2
  exit 1
fi

exec "$BIN" \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  -ngl 99 \
  --ctx-size 8192 \
  --host 127.0.0.1 \
  --port 8080
