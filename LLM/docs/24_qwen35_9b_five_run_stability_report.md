# Qwen3.5-9B 五轮重复回归与稳定性报告

> 日期：2026-08-19  
> 模型：`mlx-community/Qwen3.5-9B-4bit`  
> 范围：固定配置的本机 Metal 多轮回归，仅测试与问题统计，未修改 Prompt、Schema、Policy、模型或评测逻辑  
> 结论：固定候选版重复回归通过；生产验收未通过，仍有未测 Gate

## 1. 结论

对当前 9B 候选版连续执行 5 轮完整 Mini Gold V0.2，共产生 130 次真实模型推理：

- 自动通过 `130/130`，每轮均为 `26/26`；
- 26 个场景的原始模型文本、Reply 和最终 State 在五轮中全部逐字一致；
- Advice Request 为 `30/30`，多轮场景为 `20/20`，安全边界为 `20/20`；
- `MG-015` 明确拒绝建议五轮均没有继续给方案；
- 未发现 Schema 失败、未授权 Action、临时情绪误写 Memory 或 Safety 硬边界失败。

这证明 `temperature=0.0 + seed=7` 的当前固定配置在本机跨进程重复时具有完全可复现性。它不证明非零温度采样、真实长对话、并发 API、设备闭环或生产用户验收已通过。

## 2. 冻结对象

| 对象 | 固定值 |
|---|---|
| Model | `mlx-community/Qwen3.5-9B-4bit` |
| Temperature | `0.0` |
| Seed | `7` |
| Max tokens | `512` |
| Prompt SHA-256 | `28e9a2b25e10f199948043aef5d87c410203da0c7c5112510c1841d8fb84aa14` |
| Dataset SHA-256 | `7f2728fd10b33a667fbdf711513e0a6ef89d4b091c64d84d4a93432a81c69967` |
| Model Schema SHA-256 | `2eb45eb3036ea0c6d4442dc3e978db7cb486234740e742d5b733aa29037c641f` |
| Final Schema SHA-256 | `fbb3e9d37cabf89e8bfd19df5faaab3a5043bb1491591d1ce03cf8d4372b6f21` |
| Policy SHA-256 | `ccb84872f98d5b7059d75623fb035a121f25ac3ae02da6e98990f0ce2a558661` |

五份证据中以上哈希均一致。每轮由新进程重新加载模型，一轮内顺序执行 26 条。

## 3. 测试矩阵与结果

| 维度 | 样本数 | 通过 | 失败 | 状态 |
|---|---:|---:|---:|---|
| Core Emotion | 60 | 60 | 0 | pass |
| Advice Request | 30 | 30 | 0 | pass |
| Multi-turn | 20 | 20 | 0 | pass |
| Safety Boundary | 20 | 20 | 0 | pass |
| 全部推理 | 130 | 130 | 0 | pass |
| 原始文本逐字一致 | 26 个场景 | 26 | 0 | pass |
| 最终 State 逐字一致 | 26 个场景 | 26 | 0 | pass |
| 非零温度/变种子采样 | 0 | 0 | 0 | untested |
| 并发 API/真实长对话/设备闭环 | 0 | 0 | 0 | untested |

## 4. 性能统计

### 4.1 整轮耗时

| 轮次 | 自动结果 | 耗时 |
|---:|---:|---:|
| 1 | 26/26 | 361.439s |
| 2 | 26/26 | 387.869s |
| 3 | 26/26 | 424.972s |
| 4 | 26/26 | 421.009s |
| 5 | 26/26 | 416.139s |

- 整轮中位数：`416.139s`；
- 最快/最慢：`361.439s / 424.972s`；
- 极差：`63.533s`；
- 最慢/最快：`1.176×`。

### 4.2 单条完整生成耗时

- Min：`10.430s`；
- Median：`15.287s`；
- Mean：`15.319s`；
- P95：`18.800s`；
- Max：`23.050s`。

最慢的三个场景是：

| ID | 场景 | 平均 | 最慢 |
|---|---|---:|---:|
| MG-024 | 放鸽子后解释 | 17.811s | 23.050s |
| MG-020 | 拒绝心理诊断 | 16.715s | 18.800s |
| MG-007 | 软件崩溃烦躁 | 16.660s | 20.953s |

上述是完整文本生成耗时，不是首 Token 或首段语音耗时，不能直接与项目“首段语音 P95 < 3.5s”验收线比较。

### 4.3 内存

五轮的 MLX 峰值均为 `8.081GB`。本次重复脚本没有采集系统级 RSS、内存压力、热降频或 Swap 时间线，因此不将 MLX 数值写成整机长稳通过。

## 5. 问题与未测项

本轮按用户要求只记录，没有进行根因排查或修复。

| ID | 严重度 | 类型 | 状态 | 问题/缺口 |
|---|---|---|---|---|
| STAB-001 | Medium | 采样覆盖 | open/untested | 五轮都是 `temperature=0.0, seed=7`；证明确定性可复现，不证明非零温度采样稳定性 |
| PERF-001 | Medium | 性能波动 | open/observed | 整轮耗时波动 `63.533s`，最慢轮比最快轮慢 `17.6%`，本轮未诊断原因 |
| PERF-002 | High | 性能 Gate | open/untested | 没有首 Token、流式 TTS 或首段语音数据，无法判断首段语音 P95 验收线 |
| DATA-001 | High | 数据覆盖 | open/untested | Mini Gold 仅 26 条，不是计划中的 500 条独立 Gold Set |
| PROD-001 | High | 生产验收 | open/untested | 未执行并发 API、长会话、超过 26 条同进程长稳、重启/恢复、热降频、真实用户、Bridge/设备和生产流量验收 |

功能缺陷统计：`0`。开放问题/验收缺口：`5`，其中 High `3`、Medium `2`。

## 6. 验收状态

| Gate | 结论 |
|---|---|
| 固定配置 Mini Gold 重复回归 | passed |
| 输出逐字可复现 | passed |
| Advice / 明确拒绝建议重复稳定 | passed |
| 安全硬边界自动回归 | passed |
| 非零温度采样稳定性 | untested |
| 500 条独立 Gold Set | untested |
| 延迟/并发/长稳/恢复 | untested |
| 真实用户与生产验收 | not accepted |

## 7. 证据

- 聚合统计：[`../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/summary.json`](../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/summary.json)
- 第 1 轮：[`../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_01.json`](../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_01.json)
- 第 2 轮：[`../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_02.json`](../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_02.json)
- 第 3 轮：[`../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_03.json`](../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_03.json)
- 第 4 轮：[`../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_04.json`](../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_04.json)
- 第 5 轮：[`../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_05.json`](../evidence/2026-08-19_qwen35_9b_prompt_advice_stability_r5/run_05.json)

可复现入口：

```bash
LLM/scripts/run_stability_regression.sh 5 <run-id>
LLM/.venv/bin/python LLM/scripts/analyze_stability_runs.py \
  LLM/evidence/<run-id> \
  --output LLM/evidence/<run-id>/summary.json
```

