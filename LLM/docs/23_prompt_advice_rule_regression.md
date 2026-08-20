# Prompt 明确请求建议规则回归

> 日期：2026-08-19  
> 模型：`mlx-community/Qwen3.5-9B-4bit`  
> 状态：本机 Metal 真实推理、自动评测与 Advice 重点人工复核完成；不是训练或生产验收

> 后续状态：相同固定配置已完成 5 轮、130 次推理重复回归，自动 `130/130`，输出逐字一致；生产验收仍未通过。见 [24_qwen35_9b_five_run_stability_report.md](24_qwen35_9b_five_run_stability_report.md)。

## 1. 结论

Prompt 已增加通用 Advice 规则，最终 Mini Gold V0.2 完整回归为自动 `26/26`，Advice 重点组与“明确拒绝建议”定向回归为自动 `8/8`、人工 `8/8`。

本次达到的行为是：

- 用户明确要建议、步骤、第一句或具体说法时，先短承接，再给一个低风险、可执行的建议；
- 不回退到“发生了什么”式的信息采集追问；
- 用户明确拒绝建议时，继续倾听而不给方案；
- 多轮中从倾听切换到建议时，当前回复仍重新做一个短承接；
- 非 Advice、安静、结束、Memory、Action 与 Safety 场景没有出现过度建议回归。

## 2. Prompt 规则

实际规则位于 [`../prompts/xiaoxi_companion_v1.md`](../prompts/xiaoxi_companion_v1.md)，关键约束为：

1. 明确 Advice 意图优先于默认共情，Need 优先选 `advice/action_help`；
2. Reply 由“短承接 + 一个最小建议”组成；
3. 一次不罗列多个方案，不仅安慰，不重新采集信息；
4. 上一轮已经共情不能替代当前 Advice Reply 的短承接；
5. 明确拒绝建议时，回到 `being_heard/emotional_validation` 并停止建议。

最终 Prompt SHA-256：`28e9a2b25e10f199948043aef5d87c410203da0c7c5112510c1841d8fb84aa14`。

## 3. 重点人工复核

| ID | 场景 | 结果 | 人工判断 |
|---|---|---:|---|
| MG-011 | 与同事吵架后该怎么聊 | 通过 | 承接后给出冷静、选时机和“我”开头的说法 |
| MG-015 | 明确拒绝建议 | 通过 | Need 为 `being_heard`，只倾听和陪伴，没有继续给方案 |
| MG-021 | 要求道歉开场 | 通过 | 给出可直接使用的开场句 |
| MG-022 | 冷战后主动开口 | 通过 | 承接后给出低压力的具体开场 |
| MG-023 | 与主管谈工作量 | 通过 | 承接压力，再给出整理工作量清单的第一步 |
| MG-024 | 放鸽子后解释 | 通过 | 承接愧疚，建议承认错误、说对不起并补救，不甩锅 |
| MG-025 | 倾听后切换为建议 | 通过 | 当前轮重新承接紧张，再给“模拟一次自我介绍” |
| MG-026 | 要求最小可执行建议 | 通过 | 不追问，给出平复后发信息道歉的小步骤 |

## 4. Mini Gold 评测词表修正

完整回归中人工确认并补齐了四类合理同义表达，防止把正确输出误杀：

- MG-010：放松状态可合理判为 `emotional_validation`；
- MG-013：“安心歇会儿”可合理判为 `rest`；
- MG-024：“对不起/承认/补救”等同样表示承担错误；
- MG-026：“发条信息”与“发条消息”等价。

最终数据集 SHA-256：`7f2728fd10b33a667fbdf711513e0a6ef89d4b091c64d84d4a93432a81c69967`。

## 5. 最终结果与资源

- 完整 26 条：`26/26`；
- Advice Request：`6/6`；
- Core Emotion：`12/12`；
- Multi-turn：`4/4`；
- Safety Boundary：`4/4`；
- 完整运行时间：`399.46s`；
- 系统 peak memory footprint：约 `8.72GB`；
- Swap：`0`。

这些结果证明当前固定模型、Prompt、Schema、Policy 和 Mini Gold 组合在本机本次运行通过；不证明随机采样稳定性、真实用户体验或生产安全已验收。

## 6. 证据

- 最终完整自动证据：[`../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_prompt_advice_final_full.json`](../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_prompt_advice_final_full.json)
- 最终定向自动证据：[`../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_prompt_advice_final_targeted_v2.json`](../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_prompt_advice_final_targeted_v2.json)
- 重点人工复核：[`../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_prompt_advice_manual_review.json`](../evidence/2026-08-19_mini_gold_v0.2_qwen35_9b_prompt_advice_manual_review.json)
