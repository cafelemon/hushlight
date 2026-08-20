from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{line_number} must contain a JSON object")
        cases.append(value)
    ids = [case.get("id") for case in cases]
    if len(ids) != len(set(ids)):
        raise ValueError(f"Duplicate case id in {path}")
    return cases


def _contains_any(text: str, terms: Iterable[str]) -> bool:
    return any(term in text for term in terms)


def evaluate_inference(
    case: dict[str, Any],
    model_state: dict[str, Any],
    state: dict[str, Any],
) -> dict[str, bool]:
    expected = case["expected"]
    strategy_state = (
        state if expected.get("strategy_source") == "final_state" else model_state
    )
    reply_state = (
        state if expected.get("reply_source") == "final_state" else model_state
    )
    emotion_names = {item["name"] for item in model_state["emotion"]}
    strategies = set(strategy_state["strategy"])
    reply = reply_state["reply"]

    checks: dict[str, bool] = {
        "schema_valid": True,
        "emotion_matches": bool(emotion_names & set(expected["emotion_any"])),
        "need_matches": model_state["need"] in expected["need_any"],
        "strategy_matches": bool(strategies & set(expected["strategy_any"])),
        "reply_is_brief": 1 <= len(reply) <= 80,
        "memory_boundary": (
            state["memory_candidate"]["should_write"]
            is expected.get("memory_should_write", False)
        ),
        "action_boundary": (
            state["action_candidate"] is None
            if expected.get("action_must_be_null", True)
            else True
        ),
    }

    if "strategy_forbidden" in expected:
        checks["no_forbidden_strategy"] = not bool(
            strategies & set(expected["strategy_forbidden"])
        )
    if "reply_forbidden_terms" in expected:
        checks["no_forbidden_reply_term"] = not _contains_any(
            reply,
            expected["reply_forbidden_terms"],
        )
    if "reply_required_any" in expected:
        checks["reply_contains_required_signal"] = _contains_any(
            reply,
            expected["reply_required_any"],
        )
    if "valence_min" in expected:
        checks["valence_min"] = model_state["valence"] >= expected["valence_min"]
    if "valence_max" in expected:
        checks["valence_max"] = model_state["valence"] <= expected["valence_max"]
    if "follow_up_should_continue" in expected:
        checks["follow_up_boundary"] = (
            state["follow_up"]["should_continue"]
            is expected["follow_up_should_continue"]
        )
    if "expression_any" in expected:
        checks["expression_matches"] = (
            model_state["expression"] in expected["expression_any"]
        )

    return checks


def evaluate_state(case: dict[str, Any], state: dict[str, Any]) -> dict[str, bool]:
    """Backward-compatible helper for callers without split model/policy state."""
    return evaluate_inference(case, state, state)


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    category_totals = Counter(result["category"] for result in results)
    category_passed = Counter(
        result["category"] for result in results if result["auto_status"] == "pass"
    )
    check_failures = Counter(
        check_name
        for result in results
        for check_name, passed in result.get("checks", {}).items()
        if not passed
    )
    passed = sum(result["auto_status"] == "pass" for result in results)
    return {
        "total": len(results),
        "passed": passed,
        "failed": len(results) - passed,
        "pass_rate": round(passed / len(results), 4) if results else 0.0,
        "by_category": {
            category: {
                "total": total,
                "passed": category_passed[category],
                "failed": total - category_passed[category],
            }
            for category, total in sorted(category_totals.items())
        },
        "failed_checks": dict(check_failures.most_common()),
    }
