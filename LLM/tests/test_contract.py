import json
import unittest

from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from hushlight_llm.api import app
from hushlight_llm.engine import DEFAULT_SCHEMA_PATH, extract_json_object


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

    def test_health_exposes_local_model_status(self) -> None:
        response = TestClient(app).get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertIn(response.json()["status"], {"ready", "model_missing"})


if __name__ == "__main__":
    unittest.main()

