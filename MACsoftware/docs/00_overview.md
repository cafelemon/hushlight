# Hushlight Mac 项目总览

> 文档版本：V0.1  
> 更新日期：2026-08-13  
> 阶段：M0 工程骨架

## 1. 定位

Hushlight Mac 是小熙在 macOS 上的第一方 PC Bridge。它负责展示连接与权限状态，并在用户授权和安全规则允许时执行有限的本地动作。

## 2. 当前目标

- 建立可编译、可测试的 SwiftUI 工程。
- 提供菜单栏常驻入口与主状态窗口。
- 固定状态、权限、动作结果的领域模型和服务边界。
- 为云端连接、设备绑定和应用适配器预留替换点。

## 3. 当前不包含

- 云端与桌面设备真实连接。
- 网易云音乐、微信或其他应用控制。
- 系统权限申请、登录、自动更新、签名与公证。
- 正式安装包与生产可用性承诺。

## 4. 项目结构

```text
MACsoftware/
├── Package.swift
├── Sources/HushlightMac/
│   ├── App/
│   ├── Domain/
│   ├── Features/Dashboard/
│   └── Services/
├── Tests/HushlightMacTests/
└── docs/
```

## 5. 文档权威顺序

根目录产品文档定义 Hushlight 全局产品规则；本目录文档只细化 macOS Bridge。发生冲突时，先记录到 `07_decisions.md`，不得由代码静默改变产品规则。
