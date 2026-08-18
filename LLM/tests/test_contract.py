import json
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from hushlight_llm.api import app
from hushlight_llm.engine import (
    DEFAULT_MODEL_SCHEMA_PATH,
    DEFAULT_SCHEMA_PATH,
    InferenceResult,
    extract_json_object,
)


VALID_STATE = {
    "schema_version": "companion-state-v1",
    "emotion": [{"name": "tired", "confidence": 0.9}],
    "valence": -0.3,
    "arousal": 0.2,
    "emotion_intensity": 0.6,
    "need": "rest",
    "need_confidence": 0.8,
    "interaction_mode": "quiet_companion",
    "strategy": ["acknowledge", "offer_choice"],
    "avoid": ["premature_advice"],
    "reply": "听起来今天有点累，要不要先歇一会儿？",
    "expression": "soft_concern",
    "motion": {"intent": "slight_head_tilt", "intensity": 0.3},
    "action_candidate": None,
    "memory_candidate": {"should_write": False, "reason": "temporary_emotion"},
    "follow_up": {"should_continue": False, "wait_for_user": True},
    "confidence": 0.86,
}


class CompanionContractTest(unittest.TestCase):
    def test_schema_accepts_valid_companion_state(self) -> None:
        schema = json.loads(DEFAULT_SCHEMA_PATH.read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(VALID_STATE)

    def test_extracts_json_from_code_fence(self) -> None:
        raw = "```json\n" + json.dumps(VALID_STATE, ensure_ascii=False) + "\n```"
        self.assertEqual(extract_json_object(raw), VALID_STATE)

    def test_model_schema_excludes_policy_owned_fields(self) -> None:
        schema = json.loads(DEFAULT_MODEL_SCHEMA_PATH.read_text(encoding="utf-8"))
        self.assertNotIn("memory_candidate", schema["properties"])
        self.assertNotIn("follow_up", schema["properties"])
        self.assertNotIn("action_candidate", schema["properties"])

    def test_health_exposes_local_model_status(self) -> None:
        response = TestClient(app).get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertIn(response.json()["status"], {"ready", "model_missing"})

    def test_respond_keeps_final_state_and_exposes_policy_audit(self) -> None:
        model_state = {
            key: value
            for key, value in VALID_STATE.items()
            if key not in {"action_candidate", "memory_candidate", "follow_up"}
        }
        model_state["schema_version"] = "model-emotion-state-v1"
        result = InferenceResult(
            state=VALID_STATE,
            model_state=model_state,
            policy_decisions={"policy_version": "policy-v1"},
            raw_text=json.dumps(model_state, ensure_ascii=False),
            elapsed_seconds=0.1,
            prompt_tokens=10,
            generation_tokens=10,
            peak_memory_gb=1.0,
        )

        class FakeEngine:
            config = {"model_id": "test-model"}

            @staticmethod
            def infer(_user_text: str) -> InferenceResult:
                return result

        with patch("hushlight_llm.api.get_engine", return_value=FakeEngine()):
            response = TestClient(app).post(
                "/v1/companion/respond",
                json={"user_text": "今天有点累。"},
            )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["state"], VALID_STATE)
        self.assertEqual(payload["model_state"]["schema_version"], "model-emotion-state-v1")
        self.assertEqual(payload["policy_decisions"]["policy_version"], "policy-v1")


if __name__ == "__main__":
    unittest.main()
