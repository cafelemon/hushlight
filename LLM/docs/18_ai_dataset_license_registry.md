# Hushlight AI 数据与模型许可证登记

> 文档版本：V0.1  
> 更新日期：2026-08-14  
> 状态：初始登记；不是法律意见或 Production Training 放行  
> 上游依据：[15_ai_emotion_engine_training_plan.md](15_ai_emotion_engine_training_plan.md)

## 1. Production Training Gate

任一数据源进入正式训练前必须记录：

```text
dataset_id
source_url
snapshot_date
content_origin
license
commercial_allowed
attribution_required
personal_or_sensitive_data
copyright_risk
approved_by
approved_version
```

仓库公开、可以下载或论文可访问不等于允许商业训练。未写明许可证、内容来自影视/论坛、仅限研究或权利链不清的数据默认 `BLOCKED`。

## 2. 初始数据登记

| 数据源 | 价值 | 当前许可证证据 | Production 状态 | 当前允许用途 |
|---|---|---|---|---|
| Hushlight 自建 Gold Set | 产品场景和回归 | 项目自建；仍需标注者/来源授权记录 | `EVAL_ONLY` | 评测，禁止训练 |
| Hushlight 自建 SFT/DPO | 核心训练资产 | 待建立数据贡献与用户授权协议 | `PENDING_PROCESS` | 完成流程后再训练 |
| GoEmotions | 情绪 taxonomy、多标签基础 | Google Research 声明仓库数据为 CC BY 4.0 | `CONDITIONAL` | 保留归因和内容审查后可候选训练/评测 |
| ESConv | 情感支持策略 taxonomy | 官方声明仅限学术研究 | `BLOCKED_PRODUCTION` | 研究、标签设计；不进入商业权重 |
| CPED | 中文情绪、Dialogue Act、多模态参考 | 影视内容来源与商业授权未确认 | `BLOCKED` | 研究和内部评测设计 |
| EmpatheticDialogues | 共情情境与评测方法 | 仓库有 LICENSE，但数据商业范围需单独复核 | `BLOCKED_PENDING_REVIEW` | 研究和方法参考 |
| 厂商模型合成数据 | 扩展场景和偏好候选 | 取决于模型服务条款、输出权利和数据处理条款 | `BLOCKED_PENDING_PROVIDER` | 条款审查后再决定 |
| 种子用户真实对话 | 中文真实陪伴场景 | 需要明确同意、撤回、脱敏和用途限制 | `BLOCKED_BY_DEFAULT` | 未同意不得训练 |

证据链接：

- [Google Research 许可证说明](https://github.com/google-research/google-research)
- [ESConv 官方仓库](https://github.com/thu-coai/Emotional-Support-Conversation)
- [CPED 官方仓库](https://github.com/scutcyr/CPED)
- [EmpatheticDialogues 官方仓库](https://github.com/facebookresearch/EmpatheticDialogues)

## 3. 模型与训练依赖登记

| 依赖 | 当前证据 | 使用状态 | 复核要求 |
|---|---|---|---|
| Qwen3.5-4B | 官方模型卡标记 Apache-2.0 | O-006 候选 | 固定模型快照、许可证文本和依赖版本 |
| `mlx-community/Qwen3.5-4B-MLX-4bit` | 继承上游 Apache-2.0；本机权重 SHA-256 已固定 | 本地推理 POC | 发布前归档模型卡、转换说明与许可证文本；仍需供应链扫描 |
| Qwen3.5-9B | 官方模型卡标记 Apache-2.0 | Teacher/Fallback 候选 | 同上；另测成本和延迟 |
| ms-swift | 官方项目列出 Qwen3.5、SFT/DPO 等能力 | 训练框架候选 | 固定版本、依赖与供应链扫描 |
| 第三方 GPU 平台 | D-033 允许合成或彻底脱敏数据 | `CONDITIONAL` | DPA/条款、地域、加密、删除证明、访问审计通过后使用 |

模型许可证允许商用不代表训练数据、下游输出、商标、隐私或监管要求已经满足。

## 4. 自建数据规则

- 合成内容必须保留生成模型、Prompt/模板、生成日期和过滤版本。
- 人工编辑记录原始候选与最终内容，避免无法解释的批量改写。
- 用户数据按默认不训练处理；授权必须与产品使用同意分开。
- 联系人、消息、账号、地址、凭据、本地路径和音频身份特征必须脱敏或删除。
- 撤回后，后续数据集版本不得继续包含对应样本；已训练权重的处置规则需在收集前说明。
- 原始音频若用于声学模型，必须独立授权，不能由文本训练授权自动覆盖。
- D-033 下真实用户对话和原始音频仍不得上传第三方 GPU，即使用户已同意产品服务。
- 数据集、训练产物和评测集分别版本化并记录哈希。

## 5. 放行记录

当前没有任何外部数据集被批准进入 Hushlight Production Training Pool。首次放行必须在本节记录批准人、版本、用途、归因方式和限制。
