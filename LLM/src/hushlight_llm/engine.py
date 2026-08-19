from __future__ import annotations

import json
import re
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

from .policy import PolicyEngine


LLM_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG_PATH = LLM_ROOT / "config" / "model.json"
DEFAULT_PROMPT_PATH = LLM_ROOT / "prompts" / "xiaoxi_companion_v1.md"
DEFAULT_SCHEMA_PATH = LLM_ROOT / "schemas" / "companion_state_v1.schema.json"
DEFAULT_MODEL_SCHEMA_PATH = (
    LLM_ROOT / "schemas" / "model_emotion_state_v1.schema.json"
)


@dataclass(frozen=True)
class InferenceResult:
    state: dict[str, Any]
    model_state: dict[str, Any]
    policy_decisions: dict[str, str]
    raw_text: str
    elapsed_seconds: float
    prompt_tokens: int | None
    generation_tokens: int | None
    peak_memory_gb: float | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def extract_json_object(text: str) -> dict[str, Any]:
    cleaned = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
    cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.IGNORECASE)
    try:
        value = json.loads(cleaned)
    except json.JSONDecodeError:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start < 0 or end <= start:
            raise ValueError(f"Model did not return a JSON object: {text!r}")
        value = json.loads(cleaned[start : end + 1])
    if not isinstance(value, dict):
        raise ValueError("Model output must be a JSON object")
    return value


class CompanionEngine:
    def __init__(self, config_path: Path = DEFAULT_CONFIG_PATH) -> None:
        self.config = _read_json(config_path)
        self.model_path = LLM_ROOT / self.config["local_path"]
        self.system_prompt = DEFAULT_PROMPT_PATH.read_text(encoding="utf-8").strip()
        self.schema = _read_json(DEFAULT_SCHEMA_PATH)
        self.model_schema = _read_json(DEFAULT_MODEL_SCHEMA_PATH)
        self.validator = Draft202012Validator(self.schema)
        self.model_validator = Draft202012Validator(self.model_schema)
        self.policy = PolicyEngine()
        self._model = None
        self._processor = None

    @property
    def is_downloaded(self) -> bool:
        if not (self.model_path / "config.json").is_file():
            return False
        weight_files = self.config.get("weight_files")
        if weight_files:
            return all(
                (self.model_path / item["file"]).is_file()
                and (self.model_path / item["file"]).stat().st_size
                == item["expected_bytes"]
                for item in weight_files
            )
        weight_path = self.model_path / self.config["weight_file"]
        return weight_path.is_file() and (
            weight_path.stat().st_size == self.config["expected_weight_bytes"]
        )

    def load(self) -> None:
        if self._model is not None:
            return
        if not self.is_downloaded:
            raise FileNotFoundError(
                f"Model not found at {self.model_path}. Run LLM/scripts/download_model.sh first."
            )
        from mlx_vlm import load

        self._model, self._processor = load(str(self.model_path))

    def infer(self, user_text: str) -> InferenceResult:
        return self.infer_messages([{"role": "user", "content": user_text}])

    def infer_messages(self, messages: list[dict[str, str]]) -> InferenceResult:
        if not messages:
            raise ValueError("messages must not be empty")
        normalized_messages: list[dict[str, str]] = []
        for index, message in enumerate(messages):
            role = message.get("role")
            content = message.get("content", "").strip()
            if role not in {"user", "assistant"}:
                raise ValueError(f"messages[{index}].role must be user or assistant")
            if not content:
                raise ValueError(f"messages[{index}].content must not be empty")
            normalized_messages.append({"role": role, "content": content})
        if normalized_messages[-1]["role"] != "user":
            raise ValueError("the last message must be from the user")
        self.load()

        from mlx_vlm import apply_chat_template, generate
        from mlx_vlm.structured import build_json_schema_logits_processor

        prompt_messages = [
            {"role": "system", "content": self.system_prompt},
            *normalized_messages,
        ]
        prompt = apply_chat_template(
            self._processor,
            self._model.config,
            prompt_messages,
            num_images=0,
            enable_thinking=False,
        )
        tokenizer = (
            self._processor.tokenizer
            if hasattr(self._processor, "tokenizer")
            else self._processor
        )
        json_logits_processor = build_json_schema_logits_processor(
            tokenizer,
            self.model_schema,
        )
        started = time.perf_counter()
        response = generate(
            self._model,
            self._processor,
            prompt,
            max_tokens=int(self.config["max_tokens"]),
            temperature=float(self.config["temperature"]),
            seed=int(self.config["seed"]),
            logits_processors=[json_logits_processor],
            verbose=False,
        )
        elapsed = time.perf_counter() - started
        raw_text = response.text.strip()
        model_state = extract_json_object(raw_text)
        errors = sorted(
            self.model_validator.iter_errors(model_state),
            key=lambda item: list(item.path),
        )
        if errors:
            details = "; ".join(
                f"{'.'.join(map(str, error.path)) or '$'}: {error.message}"
                for error in errors
            )
            raise ValueError(f"ModelEmotionState validation failed: {details}")
        policy_result = self.policy.apply(normalized_messages, model_state)
        state = policy_result.state
        errors = sorted(
            self.validator.iter_errors(state),
            key=lambda item: list(item.path),
        )
        if errors:
            details = "; ".join(
                f"{'.'.join(map(str, error.path)) or '$'}: {error.message}"
                for error in errors
            )
            raise ValueError(f"Policy CompanionState validation failed: {details}")
        return InferenceResult(
            state=state,
            model_state=model_state,
            policy_decisions=policy_result.decisions,
            raw_text=raw_text,
            elapsed_seconds=round(elapsed, 3),
            prompt_tokens=getattr(response, "prompt_tokens", None),
            generation_tokens=getattr(response, "generation_tokens", None),
            peak_memory_gb=getattr(response, "peak_memory", None),
        )
