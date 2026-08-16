# Hushlight LLM 工作区

本目录是项目内大模型资产的唯一入口，统一承载模型下载、虚拟环境、Prompt、Schema、推理、本地 API、评测、LoRA/QLoRA、数据和运行证据。模型权重、虚拟环境、缓存、训练数据、适配器和运行产物只保留在本机，不提交 Git。

## 目录

```text
LLM/
├── .venv/                 # Python 3.11 独立环境，本机生成
├── config/                # 模型与运行配置
├── prompts/               # 小熙系统 Prompt
├── schemas/               # CompanionState JSON Schema
├── src/hushlight_llm/     # 推理引擎和本地 API
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

- 模型：`mlx-community/Qwen3.5-4B-MLX-4bit`
- 上游：`Qwen/Qwen3.5-4B`
- 推理框架：`mlx-vlm`
- 本地模型路径：`LLM/models/Qwen3.5-4B-MLX-4bit`

## 初始化

```bash
env UV_CACHE_DIR=LLM/.cache/uv uv venv LLM/.venv --python 3.11
env UV_CACHE_DIR=LLM/.cache/uv uv pip install --python LLM/.venv/bin/python -e LLM
sh LLM/scripts/download_model.sh
LLM/.venv/bin/python LLM/scripts/verify_model.py
```

清华 PyPI 镜像只影响 Python 依赖，不负责 Hugging Face 模型权重。若 Hugging Face 下载在开启梯子时出现 TLS/Xet 卡顿，可关闭梯子后明确取消代理变量，并对正式权重执行断点续传：

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
  curl -L --fail --retry 10 --retry-all-errors --connect-timeout 30 \
    -C - \
    -o LLM/models/Qwen3.5-4B-MLX-4bit/model.safetensors \
    'https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit/resolve/main/model.safetensors?download=true'
```

断点下载完成后必须重新运行 `verify_model.py`，不能只凭文件存在判断成功。

## 单条验收

该命令必须在可访问 Apple Metal GPU 的本机终端执行：

```bash
LLM/.venv/bin/python LLM/scripts/smoke_test.py --text '今天有点累。'
```

成功条件：JSON Schema 通过；情绪包含 `tired`；valence 不为正；需求属于休息、低刺激陪伴或被倾听；策略具有共情/倾听/选择；回复简短自然；不写入临时情绪记忆；不产生未授权动作。首条真实结果见 [evidence/2026-08-14_qwen35_4b_mlx_smoke.json](evidence/2026-08-14_qwen35_4b_mlx_smoke.json)。

## 本地 API

```bash
LLM/.venv/bin/uvicorn hushlight_llm.api:app --host 127.0.0.1 --port 8765
curl --noproxy '*' -sS http://127.0.0.1:8765/v1/companion/respond \
  -H 'Content-Type: application/json' \
  -d '{"user_text":"今天有点累。"}'
```

API 只返回模型候选语义。设备动作、记忆写入和工具执行仍必须经过项目 Policy/Bridge 权威层。
