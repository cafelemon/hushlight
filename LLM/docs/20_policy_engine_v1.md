# Hushlight Policy Engine V1 实施与回归报告

> 日期：2026-08-18
> 状态：本地实现与 20 条回归已完成；不是生产安全验收
> 决策：D-036

## 1. 结论

已完成 `ModelEmotionState → PolicyEngine → CompanionState` 两层改造。4B 模型不再输出或判断 Memory、Exit、Follow-up、Action 与 Safety 硬边界；这些字段由确定性代码生成或覆盖。

旧 Base 的 Memory 误写 2 条、安静/停止后的 Follow-up 错误 2 条，在 Policy V1 回归中全部归零。对外 `state` 继续符合 `companion-state-v1`，同时新增 `model_state` 和 `policy_decisions` 用于审计，避免把代码修正计入模型能力。

## 2. 职责边界

| 层 | 当前职责 |
|---|---|
| 4B 模型 | Emotion、Valence/Arousal、Need、Strategy、Reply、Expression、Motion 候选 |
| Memory Policy | 默认拒绝；只有“明确要求记住 + 稳定信息 + 非临时表达”才产生写入候选 |
| Interaction Policy | 安静、停止追问、结束对话、拒绝建议 |
| Tool Policy | `action_candidate` 固定为 `null`，禁止模型宣称动作成功 |
| Safety Policy | 当前覆盖明确危机表达、心理诊断、排他依赖和动作伪成功 |
| 后续服务 | 真实记忆写入、用户确认、工具执行、设备动作与结果回传 |

## 3. 真实 20 条回归

| 指标 | 改造前 Base | Policy V1 |
|---|---:|---:|
| 自动整体通过 | 14/20 | 15/20 |
| Memory Boundary | 18/20 | **20/20** |
| 明确安静/结束 Follow-up | 2 条错误 | **0 条错误** |
| Action Candidate | 20/20 null | **20/20 null** |
| 最终 CompanionState Schema | 20/20 | **20/20** |
| 模型输出含 Policy 字段 | 20/20 | **0/20** |

Policy V1 剩余 5 条自动失败不再是 Memory/Exit/Follow-up/Action 硬边界：

- MG-011、MG-012、MG-013、MG-020：4B 的 Need 枚举与测试允许范围不一致，留到后续模型比较处理。
- MG-015：最终回复“好，我先不提建议，听你说。”遵守拒绝建议，但旧规则仅按“建议”字符串命中，属于自动规则误杀。

因此本轮不能写成“4B 模型提升到 15/20”。准确口径是：系统 Policy 硬边界已从模型职责中移出并通过当前回归；4B 情绪理解和回复质量没有在本轮重新做人工准入。

## 4. 性能

- 20 条总推理时间约 `115.66s`，模型生成平均约 `5.58s/条`。
- 峰值内存约 `4.78GB`；单条烟雾测试约 `4.27GB`。
- 本轮没有更换模型、增加可用内存、进行 LoRA 或启用 8GB 级模型。

与旧 Base 的耗时差异同时受到 Prompt 和输出 Schema 缩短影响，只作为本机快照，不作为正式性能结论。

## 5. V1 已知边界

- Safety V1 是显式中文规则和确定性安全回复，不覆盖隐晦表达、错别字、英文、上下文暗示和所有心理健康风险。
- `memory_candidate.should_write=true` 仍只是候选；当前 Schema 还没有可持久化的结构化记忆内容，Memory Service 也未实现。
- Tool Policy 当前只拒绝和解释，没有接入确认、Bridge、执行回执或失败状态机。
- 后续应逐步增加规则归一化、风险分类器、强模型升级和红队集，但这些能力不得重新退回到单一 Prompt 约束。

## 6. 证据

- Policy 实现：[`../src/hushlight_llm/policy.py`](../src/hushlight_llm/policy.py)
- 模型内部 Schema：[`../schemas/model_emotion_state_v1.schema.json`](../schemas/model_emotion_state_v1.schema.json)
- 最终 CompanionState Schema：[`../schemas/companion_state_v1.schema.json`](../schemas/companion_state_v1.schema.json)
- 20 条真实回归：[`../evidence/2026-08-18_mini_gold_v0.1_policy_v1.json`](../evidence/2026-08-18_mini_gold_v0.1_policy_v1.json)
- 最终 Policy SHA-256：`ccb84872f98d5b7059d75623fb035a121f25ac3ae02da6e98990f0ce2a558661`
- Policy 单元测试：[`../tests/test_policy.py`](../tests/test_policy.py)
