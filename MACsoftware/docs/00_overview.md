# Orbit 智轨 · Mac Agent 工作台

> 文档版本：V0.2
> 更新日期：2026-10-24
> 当前状态：通用分页工作台、MCP、邮件/日历及联动源码已实现；固定签名与部分权限复用已有实机证据。QQ 原生控制待辅助功能验收，Mac 语音输入正在实现。最新测试及真实操作证据以 06_progress.md 与 12_integrated_acceptance.md 为准。

## 1. 定位

Agent 工作台是通用 macOS 本地能力控制中心。用户直接操作，Codex、小熙及其他本机 Agent 通过受控连接调用同一执行服务。首版不内置聊天、模型、记忆或设备运动控制；小熙属于调用方。显示品牌通用化，工程名、Bundle ID 和已有数据身份保持兼容。

BridgeCore 同时服务小熙与其他本机调用方；本地 CLI 是独立的软件开发和工具复用入口，无需硬件。语音识别、聊天和手机入口位于上层，只将明确意图转换为受控命令。

日常入口为菜单栏，首次配置、权限恢复、最近动作和诊断使用独立管理窗口。Dock 图标默认隐藏，用户可在设置中切换，重启应用后生效。

## 2. 三阶段主线

| 状态 | 工作 | 验收依据 |
| --- | --- | --- |
| 已完成能力实现 | 音量、计时器、提醒事项、备忘录、天气与定位 | 自动测试与已取得的实机证据分别记录 |
| 当前小步 | QQ 原生控制验收、Mac 手动语音输入及已有联动统一验收 | 本轮测试、构建及真实应用证据 |
| 后续队列 | QQ 搜索播放、微信、语音到 Agent、iPhone 入口；网易云跳过 | 每项能力真实结果与对应权限测试 |
| 后续集成与分发 | LAN/云端、签名、公证、更新 | 独立集成与发布 Gate |

以上是 Mac 软件内部阶段，不替代根项目的 K0、V0、V1 Alpha、V1 Pilot。阶段三位于 V0 功能冻结之后，负责形成 Alpha 可交付版本。

## 3. 首发能力

- 系统音量读取、绝对设置和步进调整。
- Bridge 本地计时器。
- 通过 EventKit 创建、修改和取消 macOS 提醒事项。
- 按 Bundle ID 和 HTTPS 域名白名单打开应用或内容。
- 通用媒体播放、暂停、上一首和下一首。
- QQ 音乐播放控制及实际状态回读；网易云按用户决定跳过。
- 微信精确联系人查找、草稿、明确确认后发送。

## 4. 已冻结实现基线

| 项目 | 基线 |
| --- | --- |
| 技术栈 | Swift 6、SwiftUI、macOS 13+ |
| 应用身份 | `com.hushlight.bridge.mac` |
| 形态 | 菜单栏常驻 + 独立管理窗口 + 可选 Dock 图标 |
| 阶段一连接 | Network.framework、Bonjour、WSS、配对密钥 |
| 上市主通道 | Bridge 主动建立云端 WSS 长连接 |
| 工具协议 | 保留 `bridge-v1`；本机版本化 IPC 与 STDIO MCP 网关 |
| 正式分发 | 官网 Developer ID 签名并公证的 DMG |
| 自动更新 | 固定 Sparkle `2.9.4`，引入前完成供应链评审 |

## 5. 当前实现事实

2026-10-23 工作台升级以 D-MAC-022 为准：App 持有统一服务，外部 Agent 通过受保护本地连接进入；独立调试 CLI 保持原有行为。界面、工具及系统验收结果见最新进度，以下较早证据不代表本轮验收。

当前代码包含 已接真实本地服务的 SwiftUI App、独立 `BridgeCore` library 和 `hushlight-bridge` CLI。核心复用既有协议、策略、防重放、幂等和 L3 验证；CLI 用本地标准输入提交命令，无需设备或云端。音量模拟只在 Debug 提供，真实模式通过 Core Audio 回读，默认只注册读取能力。

App 已接只读音量与暂停偏好恢复，同进程主窗口和菜单栏共享状态；GUI 手工验收因工具通道中断待补。Xcode App target、网络配对、云端与第三方应用尚未完成。软件专属验收与真实设备/云端/正式分发 Gate 分开，后者不阻塞前者。
## 6. 文档与代码结构

```text
MACsoftware/
├── Package.swift                         # App、核心库和 CLI 构建入口
├── Sources/BridgeCore/                  # 可复用执行核心与适配器
├── Sources/HushlightBridgeCLI/           # 本地标准输入命令工具
├── Sources/HushlightMac/                 # SwiftUI 状态壳
├── Tests/HushlightMacTests/              # 当前 M0 测试
└── docs/
    ├── 00_overview.md
    ├── 01_prd.md
    ├── 02_roadmap.md
    ├── 03_architecture.md
    ├── 04_acceptance_checklist.md
    ├── 05_ai_coding_agent_guide.md
    ├── 06_progress.md
    ├── 07_decisions.md
    ├── 08_bridge_protocol.md
    └── 09_local_adapter_spec.md
```

根目录产品文档定义 Hushlight 全局产品规则；本目录定义 macOS Bridge 的实现和验收。发生冲突时先更新根 PRD 或决策记录，代码不得静默改变产品行为。
