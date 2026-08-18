# Hushlight CompanionState 语义契约

> 文档版本：V0.2-proposal
> 更新日期：2026-08-18
> 状态：AI-001 评审候选；不得视为已发布 API  
> 上游依据：[01_prd.md](../../docs/01_prd.md)、[03_architecture.md](../../docs/03_architecture.md)

## 1. 目的

`CompanionState` 是系统最终语义状态，不等同于模型原始输出。模型只产生 `ModelEmotionState`：情绪、Need、Strategy、回复、表情和动作语义候选；代码 `PolicyEngine` 再负责 Memory、Exit、Follow-up、Action 与 Safety 硬边界，并合成为对外 `CompanionState V1`。

这种拆分让模型负责理解和表达，让代码负责守规矩；更换 4B/更大模型时，Policy 行为不会随权重或 Prompt 漂移。

## 2. V1 候选结构

```json
{
  "schema_version": "companion-state-v1",
  "emotion": [
    {"name": "frustrated", "confidence": 0.82},
    {"name": "tired", "confidence": 0.77}
  ],
  "valence": -0.48,
  "arousal": 0.31,
  "emotion_intensity": 0.68,
  "need": "low_stimulation_companionship",
  "need_confidence": 0.81,
  "interaction_mode": "quiet_companion",
  "strategy": ["acknowledge", "offer_choice"],
  "avoid": ["premature_advice", "cheerleading", "over_questioning"],
  "reply": "听起来今天是真没电了。要不要先什么都不管，我陪你待会儿？",
  "expression": "soft_concern",
  "motion": {"intent": "slight_head_tilt", "intensity": 0.35},
  "action_candidate": null,
  "memory_candidate": {"should_write": false, "reason": "temporary_emotion"},
  "follow_up": {"should_continue": false, "wait_for_user": true},
  "confidence": 0.86
}
```

## 3. 第一版候选枚举

### Emotion

- Positive：`happy`、`excited`、`relaxed`、`proud`、`grateful`、`curious`
- Negative：`sad`、`frustrated`、`angry`、`anxious`、`lonely`、`disappointed`、`tired`、`bored`、`overwhelmed`
- Other：`neutral`、`mixed`、`uncertain`

Emotion 允许多标签。它是交互线索，不是心理诊断。

### Need

- `companionship`
- `being_heard`
- `low_stimulation_companionship`
- `emotional_validation`
- `information`
- `advice`
- `encouragement`
- `distraction`
- `entertainment`
- `rest`
- `action_help`
- `reassurance`
- `privacy`
- `conversation_end`
- `unclear`

### Interaction Mode

- `normal_chat`
- `active_listening`
- `quiet_companion`
- `comfort`
- `playful`
- `encourage`
- `advice`
- `action`
- `high_energy`
- `conversation_closing`

### Strategy

- `listen`
- `reflect`
- `reassure`
- `acknowledge`
- `ask`
- `quiet`
- `playful`
- `encourage`
- `advise`
- `offer_choice`
- `offer_action`
- `redirect`
- `end_conversation`

### Expression

- `neutral`
- `listening`
- `soft_concern`
- `happy`
- `excited`
- `playful`
- `thinking`
- `sleepy`
- `embarrassed`
- `apologetic`

### Motion Intent

- `rest`
- `look_at_user`
- `return_center`
- `small_nod`
- `double_nod`
- `slight_head_tilt`
- `look_down`
- `curious_tilt`
- `small_shake`

模型不得输出电机角度、速度、PWM、限位绕过或连续追踪命令。设备端映射、轨迹规划、软硬限位和故障停机仍以 H0 BSP 与运动控制为权威。

## 4. 输入上下文

模型输入可以包含：

- 经过会话策略裁剪的多轮文本；
- 用户确认过的关系与偏好记忆；
- 当前设备与 Bridge 可用能力；
- 时间、静默时段和主动预算；
- 声学弱信号：能量、语速、停顿、valence/arousal 候选和不确定度。

模型输入不得包含：

- 待机摄像头图像；
- 上传或持久化的摄像头原始帧；
- 未授权的联系人、消息正文或本地路径；
- 已删除或已过期的记忆；
- 将声学特征解释为诊断结果的确定性标签。

## 5. 权威边界

| 输出 | 模型是否输出 | 最终权威 |
|---|---|---|
| Emotion / Need / Strategy | 是，候选 | 会话编排 + 后续校准 |
| Reply | 是，候选 | Safety/Interaction Policy 后播报 |
| Expression / Motion | 是，语义候选 | 设备状态机与运动仲裁 |
| Memory Candidate | **否** | 代码 Memory Policy + 用户管理 |
| Exit / Follow-up | **否** | 代码 Interaction Policy |
| Action Candidate | **否** | 代码 Tool Policy + 用户确认 + Bridge |
| Safety Override | **否** | 代码 Safety Policy；未知风险可升级强模型/人工 |
| Tool Result | **否** | Bridge/适配器真实结果 |

当前可执行模型 Schema 为 `../schemas/model_emotion_state_v1.schema.json`，最终系统 Schema 为 `../schemas/companion_state_v1.schema.json`。推理证据同时保留 `model_state` 和 `policy_decisions`，不得把 Policy 修正后的结果记作模型自身能力。

## 6. 兼容性规则

- `schema_version` 必填；枚举和字段变更必须有迁移说明。
- 新增可选字段不得改变已有安全语义。
- 删除、改名或改变枚举含义属于破坏性变更。
- Schema 校验失败时不得执行工具或写入记忆；允许降级到澄清或基础回复。
- `action_candidate` 当前由代码固定为 `null`；模型输出 Schema 中不存在该字段。
- `memory_candidate.should_write=true` 只允许来自代码识别的“明确记住请求 + 稳定信息”，仍不等于已经写入。
- 临时事件/情绪默认拒绝记忆；安静、停止追问和结束表达必须由代码关闭 Follow-up。

## 7. 评审前必须补齐

- 两层可执行 JSON Schema 已建立；正反样例仍需继续扩充；
- 与设备状态/动作词典的映射；
- 与 `bridge-v1` 的 Action Candidate 映射；
- Memory Candidate 类型、敏感级别和确认规则；
- 每个置信度字段的校准方式；
- Schema 版本升级和回放测试。
