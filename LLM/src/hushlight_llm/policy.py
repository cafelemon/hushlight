from __future__ import annotations

import copy
import re
from dataclasses import dataclass
from typing import Any


POLICY_VERSION = "policy-v1"


_QUIET_RE = re.compile(
    r"不想说话|安静(?:待|呆|一会|一下)|想静静|别问了|不要问|别再问|不想聊"
)
_END_RE = re.compile(
    r"先不聊|不聊了|先这样|下次再聊|我要睡|想睡了|晚安|到这(?:里)?吧|结束对话"
)
_NO_ADVICE_RE = re.compile(
    r"不想听建议|不要(?:再)?(?:给我)?建议|别(?:再)?(?:给我)?建议|只想(?:把这句话)?说出来|只想让你听"
)
_MEMORY_REQUEST_RE = re.compile(r"请记住|帮我记住|记住我|以后请记得|请你记得|别忘了")
_STABLE_MEMORY_RE = re.compile(
    r"我(?:一直|通常|习惯|喜欢|不喜欢|更喜欢|偏好)|我的生日|我叫|以后请"
)
_TEMPORARY_RE = re.compile(
    r"今天|现在|刚刚|刚才|这几天|这次|此刻|最近|临时|目前|这会儿"
)
_ACTION_REQUEST_RE = re.compile(
    r"(?:^|[，。！？]\s*)(?:请|你能|能不能|可以)?(?:帮我|替我|给我)"
    r"(?:给[^，。！？]{0,20})?(?:发|发送|打开|播放|关闭|关掉|提醒|预定|下单)"
)
_FAKE_ACTION_SUCCESS_RE = re.compile(
    r"已经(?:发送|发出|打开|播放|关闭|关掉|提醒|预定|下单)|发好了|发送成功|已发送成功"
)
_DIAGNOSIS_RE = re.compile(
    r"(?:我)?是不是(?:得(?:了)?|有|患上)?(?:抑郁症|焦虑症|心理疾病)|"
    r"(?:我)?会不会是(?:抑郁症|焦虑症|心理疾病)"
)
_EXCLUSIVITY_RE = re.compile(
    r"只有你(?:理解|懂|陪)|只想跟你说|只需要你|不需要别人"
)
_CRISIS_RE = re.compile(
    r"不想活了|想死|自杀|结束生命|伤害自己|杀了自己|活着没意思"
)


@dataclass(frozen=True)
class PolicyResult:
    state: dict[str, Any]
    decisions: dict[str, str]


class PolicyEngine:
    """Apply deterministic product boundaries after model inference.

    The model may describe emotion, need, conversational strategy and a reply
    candidate. This layer owns memory candidacy, action denial, follow-up/exit
    behavior and the currently implemented safety overrides.
    """

    def apply(
        self,
        messages: list[dict[str, str]],
        model_state: dict[str, Any],
    ) -> PolicyResult:
        if not messages or messages[-1].get("role") != "user":
            raise ValueError("policy requires a final user message")

        user_text = messages[-1].get("content", "").strip()
        if not user_text:
            raise ValueError("policy requires non-empty user content")

        state = copy.deepcopy(model_state)
        state["schema_version"] = "companion-state-v1"
        decisions = {
            "policy_version": POLICY_VERSION,
            "memory": "default_deny",
            "follow_up": "conversation_open",
            "action": "denied_without_tool_policy",
            "safety": "no_override",
        }

        state["action_candidate"] = None
        state["memory_candidate"] = self._memory_candidate(user_text, decisions)

        safety_override = self._apply_safety(user_text, state, decisions)
        if safety_override != "crisis_override":
            self._apply_interaction_boundary(user_text, state, decisions)

        if "follow_up" not in state:
            state["follow_up"] = {
                "should_continue": True,
                "wait_for_user": True,
            }

        return PolicyResult(state=state, decisions=decisions)

    @staticmethod
    def _memory_candidate(
        user_text: str,
        decisions: dict[str, str],
    ) -> dict[str, Any]:
        requested = bool(_MEMORY_REQUEST_RE.search(user_text))
        stable = bool(_STABLE_MEMORY_RE.search(user_text))
        temporary = bool(_TEMPORARY_RE.search(user_text))
        if requested and stable and not temporary:
            decisions["memory"] = "explicit_stable_candidate"
            return {
                "should_write": True,
                "reason": "explicit_stable_memory_request",
            }
        if requested or temporary:
            decisions["memory"] = "temporary_or_unconfirmed_denied"
            return {
                "should_write": False,
                "reason": "temporary_or_unconfirmed",
            }
        return {"should_write": False, "reason": "policy_default_deny"}

    @staticmethod
    def _apply_safety(
        user_text: str,
        state: dict[str, Any],
        decisions: dict[str, str],
    ) -> str:
        if _CRISIS_RE.search(user_text):
            state["reply"] = (
                "我很在意你现在的安全。如果你正准备伤害自己，请立即联系当地急救服务，"
                "或让身边可信任的人现在陪着你。你现在是否处在立即危险中？"
            )
            state["strategy"] = ["acknowledge", "ask"]
            state["interaction_mode"] = "active_listening"
            state["follow_up"] = {
                "should_continue": True,
                "wait_for_user": True,
            }
            decisions["safety"] = "crisis_override"
            decisions["follow_up"] = "crisis_check_required"
            return decisions["safety"]

        if _DIAGNOSIS_RE.search(user_text):
            state["reply"] = (
                "只凭这几天的状态没法判断。如果持续或已经影响生活，"
                "可以考虑找专业人士聊聊。"
            )
            state["strategy"] = ["acknowledge", "advise"]
            decisions["safety"] = "diagnosis_override"
        elif _EXCLUSIVITY_RE.search(user_text):
            state["reply"] = "我愿意听你说，也希望你身边能有值得信任的人陪着你。"
            state["strategy"] = ["acknowledge", "redirect"]
            decisions["safety"] = "exclusivity_override"
        elif _ACTION_REQUEST_RE.search(user_text):
            state["reply"] = (
                "我不会直接执行；可以先帮你准备内容，确认后再交给执行层。"
            )
            state["strategy"] = ["acknowledge", "offer_action"]
            decisions["safety"] = "action_request_override"
        elif _FAKE_ACTION_SUCCESS_RE.search(state.get("reply", "")):
            state["reply"] = "我还没有执行任何操作；需要确认后再交给执行层。"
            state["strategy"] = ["acknowledge", "offer_action"]
            decisions["safety"] = "fake_action_result_blocked"
        return decisions["safety"]

    @staticmethod
    def _apply_interaction_boundary(
        user_text: str,
        state: dict[str, Any],
        decisions: dict[str, str],
    ) -> None:
        if _END_RE.search(user_text):
            state["reply"] = "好，晚安，先好好休息。" if re.search(
                r"睡|晚安", user_text
            ) else "好，那我们先聊到这里。"
            state["strategy"] = ["acknowledge", "end_conversation"]
            state["interaction_mode"] = "conversation_closing"
            state["follow_up"] = {
                "should_continue": False,
                "wait_for_user": True,
            }
            decisions["follow_up"] = "explicit_conversation_end"
            return

        if _QUIET_RE.search(user_text):
            state["reply"] = "好，我不再追问，安静陪你一会儿。"
            state["strategy"] = ["acknowledge", "quiet"]
            state["interaction_mode"] = "quiet_companion"
            state["follow_up"] = {
                "should_continue": False,
                "wait_for_user": True,
            }
            decisions["follow_up"] = "explicit_quiet_or_stop"
            return

        if _NO_ADVICE_RE.search(user_text):
            state["reply"] = "好，我先不提建议，听你说。"
            state["strategy"] = ["listen", "acknowledge"]
            state["interaction_mode"] = "active_listening"
            state["follow_up"] = {
                "should_continue": True,
                "wait_for_user": True,
            }
            decisions["follow_up"] = "listen_without_advice"
            return

        state["follow_up"] = {
            "should_continue": True,
            "wait_for_user": True,
        }
