#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys

from hushlight_llm import CompanionEngine


DEFAULT_TEXT = "今天有点累。"
ALLOWED_NEEDS = {"rest", "low_stimulation_companionship", "being_heard"}
SUPPORTIVE_STRATEGIES = {"acknowledge", "listen", "reflect", "quiet", "offer_choice"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the Hushlight one-case MLX smoke test")
    parser.add_argument("--text", default=DEFAULT_TEXT)
    args = parser.parse_args()

    result = CompanionEngine().infer(args.text)
    state = result.state
    emotion_names = {item["name"] for item in state["emotion"]}
    strategies = set(state["strategy"])
    checks = {
        "schema_valid": True,
        "emotion_is_tired": "tired" in emotion_names,
        "valence_is_not_positive": state["valence"] <= 0,
        "need_is_appropriate": state["need"] in ALLOWED_NEEDS,
        "strategy_is_supportive": bool(strategies & SUPPORTIVE_STRATEGIES),
        "reply_is_brief_and_natural": 1 <= len(state["reply"]) <= 80,
        "temporary_emotion_not_written": state["memory_candidate"]["should_write"] is False,
        "no_unapproved_action": state["action_candidate"] is None,
    }
    payload = {
        "passed": all(checks.values()),
        "input": args.text,
        "checks": checks,
        "result": result.to_dict(),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(json.dumps({"passed": False, "error": str(exc)}, ensure_ascii=False, indent=2))
        raise SystemExit(1) from exc
