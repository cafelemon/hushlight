#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(values: list[float], percentage: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * percentage) - 1)
    return ordered[index]


def rounded(value: float) -> float:
    return round(value, 3)


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate repeated Mini Gold runs")
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    paths = sorted(args.run_dir.glob("run_*.json"))
    if not paths:
        raise ValueError(f"No run_*.json files found under {args.run_dir}")
    runs = [json.loads(path.read_text(encoding="utf-8")) for path in paths]

    run_hash_fields = [
        "model_weight_sha256",
        "prompt_sha256",
        "model_schema_sha256",
        "schema_sha256",
        "policy_sha256",
        "dataset_sha256",
    ]
    hash_consistency = {
        field: len({json.dumps(run["run"][field], sort_keys=True) for run in runs}) == 1
        for field in run_hash_fields
    }
    case_ids = [result["id"] for result in runs[0]["results"]]
    if any([result["id"] for result in run["results"]] != case_ids for run in runs):
        raise ValueError("Run case order or membership differs")

    all_results = [result for run in runs for result in run["results"]]
    all_latencies = [result["inference"]["elapsed_seconds"] for result in all_results]
    run_elapsed = [run["run"]["elapsed_seconds"] for run in runs]
    run_peak_memory = [
        max(result["inference"]["peak_memory_gb"] for result in run["results"])
        for run in runs
    ]

    per_case: list[dict[str, Any]] = []
    variable_reply_cases: list[str] = []
    variable_state_cases: list[str] = []
    for case_id in case_ids:
        results = [
            next(result for result in run["results"] if result["id"] == case_id)
            for run in runs
        ]
        replies = [result["inference"]["model_state"]["reply"] for result in results]
        raw_texts = [result["inference"]["raw_text"] for result in results]
        states = [
            json.dumps(result["inference"]["state"], ensure_ascii=False, sort_keys=True)
            for result in results
        ]
        needs = [result["inference"]["model_state"]["need"] for result in results]
        strategies = [
            json.dumps(result["inference"]["model_state"]["strategy"], sort_keys=True)
            for result in results
        ]
        latencies = [result["inference"]["elapsed_seconds"] for result in results]
        unique_replies = len(set(replies))
        unique_states = len(set(states))
        if unique_replies > 1:
            variable_reply_cases.append(case_id)
        if unique_states > 1:
            variable_state_cases.append(case_id)
        per_case.append(
            {
                "id": case_id,
                "category": results[0]["category"],
                "passes": sum(result["auto_status"] == "pass" for result in results),
                "failures": sum(result["auto_status"] != "pass" for result in results),
                "unique_raw_text_count": len(set(raw_texts)),
                "unique_reply_count": unique_replies,
                "unique_final_state_count": unique_states,
                "unique_need_count": len(set(needs)),
                "unique_strategy_count": len(set(strategies)),
                "latency_seconds": {
                    "min": rounded(min(latencies)),
                    "median": rounded(statistics.median(latencies)),
                    "max": rounded(max(latencies)),
                    "mean": rounded(statistics.mean(latencies)),
                },
            }
        )

    failed_check_counts = Counter(
        check_name
        for result in all_results
        for check_name, passed in result.get("checks", {}).items()
        if not passed
    )
    first_run = runs[0]["run"]
    summary = {
        "schemaVersion": 1,
        "subject": "Hushlight Qwen3.5-9B fixed-config five-run stability regression",
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "source_runs": [str(path) for path in paths],
        "frozen_candidate": {
            "model_id": first_run["model_id"],
            "generation": {"temperature": 0.0, "seed": 7, "max_tokens": 512},
            "hashes": {field: first_run[field] for field in run_hash_fields},
            "all_hashes_consistent": all(hash_consistency.values()),
            "hash_consistency": hash_consistency,
        },
        "automatic_results": {
            "runs": len(runs),
            "cases_per_run": len(case_ids),
            "total_inferences": len(all_results),
            "passed": sum(result["auto_status"] == "pass" for result in all_results),
            "failed": sum(result["auto_status"] != "pass" for result in all_results),
            "failed_check_counts": dict(failed_check_counts),
            "per_run_passed": [run["summary"]["passed"] for run in runs],
        },
        "output_stability": {
            "cases_with_identical_raw_text": sum(
                item["unique_raw_text_count"] == 1 for item in per_case
            ),
            "cases_with_identical_reply": sum(
                item["unique_reply_count"] == 1 for item in per_case
            ),
            "cases_with_identical_final_state": sum(
                item["unique_final_state_count"] == 1 for item in per_case
            ),
            "variable_reply_case_ids": variable_reply_cases,
            "variable_final_state_case_ids": variable_state_cases,
        },
        "performance": {
            "run_elapsed_seconds": [rounded(value) for value in run_elapsed],
            "run_elapsed_min": rounded(min(run_elapsed)),
            "run_elapsed_median": rounded(statistics.median(run_elapsed)),
            "run_elapsed_max": rounded(max(run_elapsed)),
            "run_elapsed_range": rounded(max(run_elapsed) - min(run_elapsed)),
            "run_elapsed_max_over_min": rounded(max(run_elapsed) / min(run_elapsed)),
            "inference_latency_seconds": {
                "min": rounded(min(all_latencies)),
                "median": rounded(statistics.median(all_latencies)),
                "p95": rounded(percentile(all_latencies, 0.95)),
                "max": rounded(max(all_latencies)),
                "mean": rounded(statistics.mean(all_latencies)),
            },
            "mlx_peak_memory_gb_per_run": [rounded(value) for value in run_peak_memory],
            "mlx_peak_memory_gb_max": rounded(max(run_peak_memory)),
        },
        "per_case": per_case,
        "issues": [
            {
                "id": "STAB-001",
                "type": "coverage_gap",
                "severity": "medium",
                "status": "open_untested",
                "finding": "All five runs used temperature=0.0 and seed=7; exact repeatability does not establish non-zero-temperature sampling stability.",
            },
            {
                "id": "PERF-001",
                "type": "performance_variation",
                "severity": "medium",
                "status": "open_observed",
                "finding": "Whole-suite elapsed time varied across repeated fresh processes; root cause was not investigated in this test-only run.",
            },
            {
                "id": "PERF-002",
                "type": "acceptance_gap",
                "severity": "high",
                "status": "open_untested",
                "finding": "The evaluator records full-generation latency, not first-token or first-audio latency, so the product P95 first-audio target cannot be assessed from these runs.",
            },
            {
                "id": "DATA-001",
                "type": "coverage_gap",
                "severity": "high",
                "status": "open_untested",
                "finding": "Mini Gold V0.2 contains only 26 cases and is not the planned 500-case independent Gold Set.",
            },
            {
                "id": "PROD-001",
                "type": "acceptance_gap",
                "severity": "high",
                "status": "open_untested",
                "finding": "No concurrent API load, long-session soak, restart/recovery, thermal throttling, real user, Bridge/device, or production traffic acceptance was performed.",
            },
        ],
        "evidence_boundary": "This is a fixed-config local repeated regression. It is not stochastic-sampling, real-user, integration, load, soak, or production acceptance evidence.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({key: summary[key] for key in ["automatic_results", "output_stability", "performance", "issues"]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
