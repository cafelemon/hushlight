#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
import time
from datetime import datetime
from importlib.metadata import version
from pathlib import Path

from hushlight_llm import CompanionEngine
from hushlight_llm.engine import (
    DEFAULT_MODEL_SCHEMA_PATH,
    DEFAULT_PROMPT_PATH,
    DEFAULT_SCHEMA_PATH,
    LLM_ROOT,
)
from hushlight_llm.evaluation import evaluate_state, load_jsonl, summarize_results


DEFAULT_DATASET = LLM_ROOT / "data" / "eval" / "mini_gold_v0.1.jsonl"
DEFAULT_POLICY_PATH = LLM_ROOT / "src" / "hushlight_llm" / "policy.py"
DEFAULT_OUTPUT = (
    LLM_ROOT / "runs" / "mini_gold_latest.json"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate Hushlight Mini Gold Set")
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--case", action="append", dest="case_ids")
    args = parser.parse_args()

    cases = load_jsonl(args.dataset)
    if args.case_ids:
        selected = set(args.case_ids)
        cases = [case for case in cases if case["id"] in selected]
        missing = selected - {case["id"] for case in cases}
        if missing:
            raise ValueError(f"Unknown case ids: {sorted(missing)}")
    if not cases:
        raise ValueError("No evaluation cases selected")

    engine = CompanionEngine()
    results = []
    run_started = time.perf_counter()
    for index, case in enumerate(cases, 1):
        print(
            f"[{index:02d}/{len(cases):02d}] {case['id']} {case['name']}",
            file=sys.stderr,
            flush=True,
        )
        try:
            inference = engine.infer_messages(case["messages"])
            checks = evaluate_state(case, inference.state)
            status = "pass" if all(checks.values()) else "fail"
            result = {
                "id": case["id"],
                "category": case["category"],
                "name": case["name"],
                "messages": case["messages"],
                "expected": case["expected"],
                "review_focus": case["review_focus"],
                "auto_status": status,
                "checks": checks,
                "inference": inference.to_dict(),
                "error": None,
            }
        except Exception as exc:
            result = {
                "id": case["id"],
                "category": case["category"],
                "name": case["name"],
                "messages": case["messages"],
                "expected": case["expected"],
                "review_focus": case["review_focus"],
                "auto_status": "fail",
                "checks": {"inference_completed": False},
                "inference": None,
                "error": f"{type(exc).__name__}: {exc}",
            }
        results.append(result)
        print(
            f"  -> {result['auto_status'].upper()}",
            file=sys.stderr,
            flush=True,
        )

    evidence = {
        "schemaVersion": 1,
        "subject": (
            f"Hushlight {engine.config['model_id']} Mini Gold V0.1 evaluation"
        ),
        "run": {
            "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "elapsed_seconds": round(time.perf_counter() - run_started, 3),
            "machine": platform.platform(),
            "python": platform.python_version(),
            "packages": {
                "mlx": version("mlx"),
                "mlx-lm": version("mlx-lm"),
                "mlx-vlm": version("mlx-vlm"),
            },
            "model_id": engine.config["model_id"],
            "model_weight_sha256": (
                {
                    item["file"]: item["expected_sha256"]
                    for item in engine.config["weight_files"]
                }
                if engine.config.get("weight_files")
                else engine.config["expected_weight_sha256"]
            ),
            "prompt_sha256": _sha256(DEFAULT_PROMPT_PATH),
            "model_schema_sha256": _sha256(DEFAULT_MODEL_SCHEMA_PATH),
            "schema_sha256": _sha256(DEFAULT_SCHEMA_PATH),
            "policy_sha256": _sha256(DEFAULT_POLICY_PATH),
            "dataset_path": str(args.dataset),
            "dataset_sha256": _sha256(args.dataset),
        },
        "summary": summarize_results(results),
        "results": results,
        "evidence_boundary": (
            "Automated range checks identify likely defects but do not replace human "
            "judgment of companionship quality, naturalness, or production acceptance."
        ),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(evidence["summary"], ensure_ascii=False, indent=2))
    print(f"Evidence: {args.output}")
    return 0 if evidence["summary"]["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
