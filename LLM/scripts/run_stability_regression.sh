#!/bin/zsh

set -u

SCRIPT_DIR=${0:A:h}
LLM_ROOT=${SCRIPT_DIR:h}
REPO_ROOT=${LLM_ROOT:h}
RUNS=${1:-5}
RUN_ID=${2:-2026-08-19_qwen35_9b_prompt_advice_stability_r5}
OUTPUT_DIR="$LLM_ROOT/evidence/$RUN_ID"

mkdir -p "$OUTPUT_DIR"

overall_status=0
for run_number in $(seq 1 "$RUNS"); do
  run_label=$(printf "%02d" "$run_number")
  output_path="$OUTPUT_DIR/run_${run_label}.json"
  echo "[stability ${run_label}/${RUNS}] starting"
  started_at=$SECONDS
  env PYTHONPATH="$LLM_ROOT/src" \
    "$LLM_ROOT/.venv/bin/python" \
    "$LLM_ROOT/scripts/evaluate_mini_gold.py" \
    --dataset "$LLM_ROOT/data/eval/mini_gold_v0.2.jsonl" \
    --output "$output_path"
  run_status=$?
  elapsed=$((SECONDS - started_at))
  echo "[stability ${run_label}/${RUNS}] exit=${run_status} elapsed=${elapsed}s evidence=${output_path}"
  if [[ $run_status -ne 0 ]]; then
    overall_status=1
  fi
done

exit $overall_status
