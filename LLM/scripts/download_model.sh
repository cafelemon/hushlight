#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LLM_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MODEL_ID="mlx-community/Qwen3.5-4B-MLX-4bit"
MODEL_DIR="$LLM_ROOT/models/Qwen3.5-4B-MLX-4bit"

export HF_HOME="$LLM_ROOT/.cache/huggingface"
export HF_XET_CACHE="$LLM_ROOT/.cache/huggingface/xet"
# The current network path can stall on Xet CAS. Standard HTTP is slower but
# observable and resumable for this single local model download.
export HF_HUB_DISABLE_XET=1

"$LLM_ROOT/.venv/bin/hf" download "$MODEL_ID" --local-dir "$MODEL_DIR"
