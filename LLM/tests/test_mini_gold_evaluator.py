import unittest

from hushlight_llm.evaluation import (
    evaluate_inference,
    evaluate_state,
    load_jsonl,
    summarize_results,
)
from hushlight_llm.engine import LLM_ROOT


class MiniGoldEvaluatorTest(unittest.TestCase):
    def test_v02_contains_fixed_baseline_and_advice_group(self) -> None:
        cases = load_jsonl(LLM_ROOT / "data" / "eval" / "mini_gold_v0.2.jsonl")
        self.assertEqual(len(cases), 26)
        advice_cases = [case for case in cases if case["category"] == "advice_request"]
        self.assertEqual(len(advice_cases), 6)
        self.assertTrue(
            all("advice" in case["expected"]["need_any"] for case in advice_cases)
        )
        self.assertTrue(
            all("advise" in case["expected"]["strategy_any"] for case in advice_cases)
        )

    def test_split_sources_keep_model_need_and_policy_reply_separate(self) -> None:
        case = {
            "expected": {
                "emotion_any": ["anxious"],
                "need_any": ["emotional_validation"],
                "strategy_any": ["advise"],
                "strategy_source": "final_state",
                "reply_source": "final_state",
                "reply_required_any": ["专业"],
                "memory_should_write": False,
                "action_must_be_null": True,
            }
        }
        model_state = {
            "emotion": [{"name": "anxious"}],
            "need": "emotional_validation",
            "strategy": ["ask"],
            "reply": "你最近怎么样？",
            "valence": -0.2,
            "expression": "soft_concern",
        }
        final_state = {
            **model_state,
            "strategy": ["advise"],
            "reply": "持续影响生活时，可以找专业人士聊聊。",
            "memory_candidate": {"should_write": False},
            "action_candidate": None,
            "follow_up": {"should_continue": True},
        }
        self.assertTrue(
            all(evaluate_inference(case, model_state, final_state).values())
        )

    def test_evaluates_expected_ranges_and_boundaries(self) -> None:
        case = {
            "expected": {
                "emotion_any": ["tired"],
                "need_any": ["rest"],
                "strategy_any": ["acknowledge"],
                "strategy_forbidden": ["advise"],
                "reply_required_any": ["歇"],
                "reply_forbidden_terms": ["加油"],
                "valence_max": 0,
                "memory_should_write": False,
                "action_must_be_null": True,
                "follow_up_should_continue": False,
            }
        }
        state = {
            "emotion": [{"name": "tired", "confidence": 0.9}],
            "valence": -0.2,
            "need": "rest",
            "strategy": ["acknowledge", "quiet"],
            "reply": "先歇一会儿吧。",
            "memory_candidate": {"should_write": False},
            "action_candidate": None,
            "follow_up": {"should_continue": False},
            "expression": "soft_concern",
        }
        self.assertTrue(all(evaluate_state(case, state).values()))

    def test_summary_counts_failed_checks(self) -> None:
        summary = summarize_results(
            [
                {
                    "category": "core",
                    "auto_status": "pass",
                    "checks": {"need_matches": True},
                },
                {
                    "category": "core",
                    "auto_status": "fail",
                    "checks": {"need_matches": False},
                },
            ]
        )
        self.assertEqual(summary["passed"], 1)
        self.assertEqual(summary["failed"], 1)
        self.assertEqual(summary["failed_checks"], {"need_matches": 1})


if __name__ == "__main__":
    unittest.main()
