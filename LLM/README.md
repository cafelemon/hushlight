# Hushlight LLM 工作区

本目录是项目内大模型资产的唯一入口，统一承载模型下载、虚拟环境、Prompt、Schema、推理、本地 API、评测、LoRA/QLoRA、数据和运行证据。模型权重、虚拟环境、缓存、训练数据、适配器和运行产物只保留在本机，不提交 Git。

## 目录

```text
LLM/
├── .venv/                 # Python 3.11 独立环境，本机生成
├── config/                # 模型与运行配置
├── prompts/               # 小熙系统 Prompt
├── schemas/               # ModelEmotionState 与最终 CompanionState Schema
├── src/hushlight_llm/     # 推理、确定性 Policy Engine 和本地 API
├── scripts/               # 下载、烟雾测试与后续训练脚本
├── evidence/              # 可提交的模型版本、指标和验收证据
├── models/                # 下载模型，不提交 Git
├── adapters/              # LoRA/QLoRA 适配器，不提交 Git
├── data/                  # 原始/处理后训练数据，不提交 Git
├── runs/                  # 实验结果与日志，不提交 Git
└── docs/                  # 模型、训练、评测和数据治理文档
```

专项文档索引见 [docs/README.md](docs/README.md)，用户提供的原始训练架构也已复制到 `docs/reference/` 保存追溯。

## 当前模型

- 当前评测模型：`mlx-community/Qwen3.5-9B-4bit`
- 本地保留基线：`mlx-community/Qwen3.5-4B-MLX-4bit`
- 上游：`Qwen/Qwen3.5-9B`
- 推理框架：`mlx-vlm`
- 当前模型路径：`LLM/models/Qwen3.5-9B-4bit`

## 初始化

```bash
env UV_CACHE_DIR=LLM/.cache/uv uv venv LLM/.venv --python 3.11
env UV_CACHE_DIR=LLM/.cache/uv uv pip install --python LLM/.venv/bin/python -e LLM
sh LLM/scripts/download_model.sh
LLM/.venv/bin/python LLM/scripts/verify_model.py
```

清华 PyPI 镜像只影响 Python 依赖，不负责 Hugging Face 模型权重。模型下载入口跟随当前 `config/model.json` 对应版本：

```bash
sh LLM/scripts/download_model.sh
LLM/.venv/bin/python LLM/scripts/verify_model.py
```

9B 使用两个权重分片；下载后必须运行 `verify_model.py` 对每个分片执行大小和 SHA-256 校验，不能只凭文件存在判断成功。

## 单条验收

该命令必须在可访问 Apple Metal GPU 的本机终端执行：

```bash
LLM/.venv/bin/python LLM/scripts/smoke_test.py --text '今天有点累。'
```

成功条件：JSON Schema 通过；情绪包含 `tired`；valence 不为正；需求属于休息、低刺激陪伴或被倾听；策略具有共情/倾听/选择；回复简短自然；不写入临时情绪记忆；不产生未授权动作。首条真实结果见 [evidence/2026-08-14_qwen35_4b_mlx_smoke.json](evidence/2026-08-14_qwen35_4b_mlx_smoke.json)。

## Mini Gold 批量评测

```bash
LLM/.venv/bin/python LLM/scripts/evaluate_mini_gold.py
```

V0.1 包含 20 条核心陪伴、多轮拒绝/纠正和安全边界样例。9B 与可比的 4B+Policy 自动结果同为 `15/20`；人工复核最终系统输出为 9B `19/20`、4B `18/20`，但 9B 平均生成延迟约为 4B 的 `2.17` 倍。详见 [9B 对照报告](docs/21_qwen35_9b_comparison_evaluation.md)。自动枚举检查不能替代人工对自然度、说教感和真实理解的判断。

## 本地 API

```bash
LLM/.venv/bin/uvicorn hushlight_llm.api:app --host 127.0.0.1 --port 8765
curl --noproxy '*' -sS http://127.0.0.1:8765/v1/companion/respond \
  -H 'Content-Type: application/json' \
  -d '{"user_text":"今天有点累。"}'
```

API 返回 Policy 后的最终 `state`，并同时保留模型原始 `model_state` 和可审计的 `policy_decisions`。设备动作、真实记忆写入和工具执行仍必须经过后续用户确认、Policy/Bridge 权威层。
