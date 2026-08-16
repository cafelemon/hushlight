# Hushlight LLM 文档索引

本目录是模型选择、Prompt、Schema、训练、评测和数据治理文档的唯一专项入口。项目级 PRD、架构、验收与决策仍位于 `../../docs/`；两者冲突时，以 `../../docs/07_decisions.md` 和对应项目级权威文档为准。

| 文档 | 用途 | 状态 |
|---|---|---|
| [15_ai_emotion_engine_training_plan.md](15_ai_emotion_engine_training_plan.md) | 4B 主力、Fallback、SFT/DPO、资源与数据路线 | V0.1 基线 |
| [16_companion_state_schema.md](16_companion_state_schema.md) | Emotion、Need、Strategy、Reply、动作和记忆候选语义契约 | V0.1 proposal；可执行 JSON Schema 见 `../schemas/` |
| [17_ai_model_evaluation_protocol.md](17_ai_model_evaluation_protocol.md) | Gold Set、Pairwise、安全 Gate、Shadow 与准入证据 | V0.1 基线 |
| [18_ai_dataset_license_registry.md](18_ai_dataset_license_registry.md) | 数据、模型和第三方训练平台许可证登记 | V0.1；无默认 Production 放行 |
| [原始训练架构 V1.0](reference/Hushlight_AI_Emotion_Engine_Training_Architecture_V1.0.md) | 用户提供的输入材料原文，保留用于追溯 | SHA-256 与桌面原件一致 |

可执行资产分别位于：

- `../prompts/`：实际推理 Prompt；
- `../schemas/`：机器可校验的 JSON Schema；
- `../config/`：模型与生成配置；
- `../scripts/`：下载、烟雾测试和后续训练入口；
- `../src/hushlight_llm/`：推理与本地 API 实现。

