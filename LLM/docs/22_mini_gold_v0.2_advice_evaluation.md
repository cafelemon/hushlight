# Mini Gold V0.2 与明确请求建议能力评测

> 日期：2026-08-19  
> 模型：`mlx-community/Qwen3.5-9B-4bit`  
> Prompt / Schema / Policy：保持 9B V0.1 对照版本不变  
> 状态：本机真实推理与人工复核完成；不是训练、用户或生产验收

> 后续状态：本文保留 Prompt 修改前的 `24/26` 基线。通用 Advice 规则修改后已达到完整 `26/26`、重点定向自动/人工 `8/8`，见 [23_prompt_advice_rule_regression.md](23_prompt_advice_rule_regression.md)。

## 1. 结论

Mini Gold V0.2 已完成，最终结果为自动 `24/26`、人工 `24/26`。原 20 条为 `19/20`，新增建议能力组为 `5/6`。

四条 V0.1 自动误杀已经修正，并且没有掩盖 `MG-011` 的真实失败。新增组进一步确认：9B 并非普遍不会给建议，但在人际冲突、后悔和修复关系场景中，会过度选择情绪确认并主动回避即时建议。

确认失败：

- `MG-011`：用户问“我该怎么跟同事聊”，Need 仍为 `emotional_validation`，Strategy 没有 `advise`；
- `MG-021`：用户明确要求一句道歉开场，模型只肯定道歉心意，没有给出开场句。

## 2. V0.1 四条误杀修正

| ID | 原问题 | V0.2 修正 | 9B 结果 |
|---|---|---|---:|
| MG-008 | 不接受低刺激陪伴 Need | 加入 `low_stimulation_companionship` | 通过 |
| MG-014 | 只接受“没过”等字面词 | 加入“没通过/准备了这么久”等同义表达 | 通过 |
| MG-015 | “不提建议”也被“建议”字符串误杀 | 只禁止真正给建议的短语，并标明 Reply/Strategy 来自 Policy | 通过 |
| MG-020 | 不接受合理的情绪确认 Need | 加入 `emotional_validation`，安全回复仍由 Policy 检查 | 通过 |

V0.2 使用 `model_state` 检查模型负责的 Emotion/Need，使用最终 `state` 检查 Memory/Follow-up/Action；只有明确标记的 Policy 场景才从最终状态检查 Reply/Strategy。

## 3. 新增建议能力组

| ID | 场景 | 自动 | 人工判断 |
|---|---|---:|---|
| MG-021 | 会议冲突后要求道歉开场 | 失败 | 确认失败，只安慰，没有给开场句 |
| MG-022 | 冷战后主动开口 | 通过 | 给出可直接使用的开场方式 |
| MG-023 | 与主管谈工作量 | 通过 | 给出整理任务、负荷和卡点的第一步 |
| MG-024 | 放鸽子后如何解释 | 通过 | 建议先承担影响再解释，不甩锅 |
| MG-025 | 多轮中从倾听切换到建议 | 通过 | Need/Strategy 成功切换，给出单一准备动作 |
| MG-026 | 明确要求最小可执行建议 | 通过 | 不再追问，给出暂停联系和平复情绪的步骤 |

建议组的模型通过率为 `5/6`。其中 `MG-026` 初始禁止词把“先别急着自责”误判为回避建议，人工确认其同时给出了具体步骤后，收紧规则并重新完整运行 26 条；最终数据集 SHA 与证据一致。

## 4. 失败模式

`MG-011` 与 `MG-021` 都具有以下结构：

1. 用户描述人际冲突或后悔；
2. 用户明确问“该怎么聊/第一句话怎么说”；
3. 模型将 Need 判为 `emotional_validation`；
4. 模型 Strategy 选择 `reassure/ask`，并在 avoid 中主动写入 `immediate advice`；
5. 回复停留在安慰或继续了解，没有完成用户已明确提出的建议任务。

这是模型职责内的 Need/Strategy/Reply 缺陷，不能交给 Memory、Exit、Follow-up 或 Safety Policy 代替解决。

## 5. 性能

- 26 条运行时间：`368.63s`
- 平均生成时间：`14.02s/条`
- 最慢单条：`18.73s`
- MLX 峰值内存：`7.91GB`
- 系统峰值 footprint：`8.50GB`
- Swap：`0`

## 6. 下一步建议

先不训练。建议在 Prompt 中增加一条通用、非句子补丁式规则：

> 当用户明确请求建议、步骤、说法或第一句话，且不触发安全限制时，Need 优先为 advice/action_help；先用一句承接感受，再给一个最小、可逆、低风险的具体建议，不要重新退回信息采集式追问。

修改后只先回归：

- 6 条 Advice Request 组；
- `MG-015` 明确拒绝建议；
- `MG-012/MG-013/MG-016` 安静与结束边界；
- 全量 26 条。

这样可以同时验证“该建议时建议”和“不该建议时收住”，避免为提高 Advice 命中率造成过度建议。

## 7. 证据

- 数据集：[`../data/eval/mini_gold_v0.2.jsonl`](../data/eval/mini_gold_v0.2.jsonl)
- 自动原始证据：[`../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b.json`](../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b.json)
- 人工复核：[`../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_manual_review.json`](../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_manual_review.json)
