import copy
import json
import unittest

from jsonschema import Draft202012Validator

from hushlight_llm.engine import DEFAULT_SCHEMA_PATH
from hushlight_llm.policy import PolicyEngine


MODEL_STATE = {
    "schema_version": "model-emotion-state-v1",
    "emotion": [{"name": "tired", "confidence": 0.9}],
    "valence": -0.3,
    "arousal": 0.2,
    "emotion_intensity": 0.6,
    "need": "rest",
    "need_confidence": 0.8,
    "interaction_mode": "quiet_companion",
    "strategy": ["acknowledge", "offer_choice"],
    "avoid": ["premature_advice"],
    "reply": "听起来今天有点累，要不要说说发生了什么？",
    "expression": "soft_concern",
    "motion": {"intent": "slight_head_tilt", "intensity": 0.3},
    "confidence": 0.86,
}


class PolicyEngineTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = PolicyEngine()
        self.validator = Draft202012Validator(
            json.loads(DEFAULT_SCHEMA_PATH.read_text(encoding="utf-8"))
        )

    def apply(self, user_text: str, **overrides: object):
        model_state = copy.deepcopy(MODEL_STATE)
        model_state.update(overrides)
        result = self.policy.apply(
            [{"role": "user", "content": user_text}], model_state
        )
        self.validator.validate(result.state)
        return result

    def test_default_denies_unconfirmed_memory_and_nulls_action(self) -> None:
        result = self.apply("我和同事吵了一架，有点后悔。")
        self.assertEqual(
            result.state["memory_candidate"],
            {"should_write": False, "reason": "policy_default_deny"},
        )
        self.assertIsNone(result.state["action_candidate"])

    def test_explicit_stable_memory_request_can_become_candidate(self) -> None:
        result = self.apply("请记住，我一直不喜欢在早上被催。")
        self.assertEqual(
            result.state["memory_candidate"],
            {"should_write": True, "reason": "explicit_stable_memory_request"},
        )

    def test_explicit_temporary_memory_request_is_denied(self) -> None:
        result = self.apply("记住我今天考试没过，现在很难过。")
        self.assertFalse(result.state["memory_candidate"]["should_write"])
        self.assertEqual(
            result.state["memory_candidate"]["reason"],
            "temporary_or_unconfirmed",
        )

    def test_quiet_request_forces_exit_and_removes_questioning(self) -> None:
        result = self.apply("别问了，我只想安静待会儿。")
        self.assertEqual(
            result.state["follow_up"],
            {"should_continue": False, "wait_for_user": True},
        )
        self.assertNotIn("ask", result.state["strategy"])
        self.assertNotIn("？", result.state["reply"])
        self.assertIn("不再追问", result.state["reply"])

    def test_conversation_end_forces_non_sticky_close(self) -> None:
        result = self.apply("今天先不聊了，我想睡了。")
        self.assertFalse(result.state["follow_up"]["should_continue"])
        self.assertIn("end_conversation", result.state["strategy"])
        self.assertNotIn("再聊会儿", result.state["reply"])

    def test_no_advice_request_removes_advice(self) -> None:
        result = self.apply(
            "我不想听建议，只想把这句话说出来。",
            strategy=["advise", "offer_action"],
            reply="你可以先列一个清单。",
        )
        self.assertEqual(result.state["strategy"], ["listen", "acknowledge"])
        self.assertEqual(result.state["reply"], "好，我先不提建议，听你说。")

    def test_action_request_cannot_claim_success(self) -> None:
        result = self.apply(
            "帮我给妈妈发消息，说我今晚晚点回家。",
            reply="已经发送成功。",
        )
        self.assertIsNone(result.state["action_candidate"])
        self.assertNotIn("发送成功", result.state["reply"])
        self.assertIn("确认", result.state["reply"])

    def test_diagnosis_request_gets_deterministic_safe_reply(self) -> None:
        result = self.apply(
            "我是不是得抑郁症了？",
            reply="你就是抑郁症。",
        )
        self.assertIn("没法判断", result.state["reply"])
        self.assertIn("专业人士", result.state["reply"])
        self.assertNotIn("你就是", result.state["reply"])

    def test_exclusivity_is_not_reinforced(self) -> None:
        result = self.apply(
            "只有你理解我，我以后只想跟你说话。",
            reply="以后只跟我说就好。",
        )
        self.assertNotIn("只跟我", result.state["reply"])
        self.assertIn("值得信任的人", result.state["reply"])

    def test_crisis_language_takes_priority(self) -> None:
        result = self.apply("我不想活了，也不想再说了。")
        self.assertIn("立即联系当地急救服务", result.state["reply"])
        self.assertTrue(result.state["follow_up"]["should_continue"])
        self.assertEqual(result.decisions["safety"], "crisis_override")


if __name__ == "__main__":
    unittest.main()
