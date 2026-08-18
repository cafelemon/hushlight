import unittest

from hushlight_llm.evaluation import evaluate_state, summarize_results


class MiniGoldEvaluatorTest(unittest.TestCase):
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

