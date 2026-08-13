# Hushlight Mac 项目总览

> 文档版本：V0.2
> 更新日期：2026-08-13
> 当前状态：M0 工程骨架已完成；三阶段开发基线已冻结，业务能力尚未实现

## 1. 定位

Hushlight Mac 是小熙在 macOS 上的第一方 PC Bridge。它只负责本机连接、权限、受控动作、真实结果、诊断和产品更新，不承载聊天、角色、记忆、订阅、ASR、TTS 或设备运动控制。

日常入口为菜单栏，首次配置、权限恢复、最近动作和诊断使用独立管理窗口。Dock 图标默认隐藏，用户可在设置中切换，重启应用后生效。

## 2. 三阶段主线

| 阶段 | 目标 | 预计周期 | 核心 Gate |
| --- | --- | ---: | --- |
| 阶段一：局域网研发闭环 | 全部本地能力通过真实设备和 Debug 测试台执行 | 9–11 周 | 网易云、微信和系统能力均有真实结果证据 |
| 阶段二：云端完整闭环 | 接入云端长连接，完成计划上市功能并冻结行为 | 5–7 周，不含外部等待 | 设备→云端→Mac→应用→设备反馈全链路通过 |
| 阶段三：正式产品准备 | 官网 DMG、签名、公证、更新、回滚、卸载和兼容验证 | 4–5 周 | 全新 Mac 可独立安装并通过发布 Gate |

以上是 Mac 软件内部阶段，不替代根项目的 K0、V0、V1 Alpha、V1 Pilot。阶段三位于 V0 功能冻结之后，负责形成 Alpha 可交付版本。

## 3. 首发能力

- 系统音量读取、绝对设置和步进调整。
- Bridge 本地计时器。
- 通过 EventKit 创建、修改和取消 macOS 提醒事项。
- 按 Bundle ID 和 HTTPS 域名白名单打开应用或内容。
- 通用媒体播放、暂停、上一首和下一首。
- 网易云音乐搜索播放及实际状态回读。
- 微信精确联系人查找、草稿、明确确认后发送。

## 4. 已冻结实现基线

| 项目 | 基线 |
| --- | --- |
| 技术栈 | Swift 6、SwiftUI、macOS 13+ |
| 应用身份 | `com.hushlight.bridge.mac` |
| 形态 | 菜单栏常驻 + 独立管理窗口 + 可选 Dock 图标 |
| 阶段一连接 | Network.framework、Bonjour、WSS、配对密钥 |
| 上市主通道 | Bridge 主动建立云端 WSS 长连接 |
| 工具协议 | 版本化私有 `bridge-v1`；后续可在外层增加 MCP 网关 |
| 正式分发 | 官网 Developer ID 签名并公证的 DMG |
| 自动更新 | 固定 Sparkle `2.9.4`，引入前完成供应链评审 |

## 5. 当前实现事实

当前代码仅包含 SwiftPM 可执行骨架、主窗口、菜单栏入口、状态模型、占位服务和两项单元测试。尚未建立 Xcode App target，未申请系统权限，未连接真实设备、云端、网易云音乐或微信，也未形成正式安装包。

## 6. 文档与代码结构

```text
MACsoftware/
├── Package.swift                         # 当前 M0 构建入口
├── Sources/HushlightMac/                 # 当前 M0 源码
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
