# Hushlight Mac 决策记录

## D-MAC-001 采用原生 SwiftUI 主线

| 项目 | 内容 |
| --- | --- |
| 状态 | Accepted |
| 日期 | 2026-08-13 |
| 决策 | macOS Bridge 使用 Swift 6、SwiftUI 和原生系统框架；最低系统先定为 macOS 13 |
| 原因 | 菜单栏、登录项、Keychain、权限、签名和系统自动化均需要深度 macOS 集成，原生方案边界最直接 |
| 影响 | Windows 可独立选型，但两端必须共享动作和错误契约 |

## D-MAC-002 M0 使用 SwiftPM 骨架

| 项目 | 内容 |
| --- | --- |
| 状态 | Accepted |
| 日期 | 2026-08-13 |
| 决策 | M0 先以 SwiftPM executable 建立可编译、可测试的 UI 与服务边界；M1 再加入正式 Xcode App target |
| 原因 | 当前 Bundle ID、Team、Entitlements 和发布渠道未确定，不应在骨架期伪造发布配置 |
| 影响 | M0 的 `swift run` 是开发预览，不代表正式 `.app` 交付 |

## D-MAC-003 未集成能力必须显示真实空状态

| 项目 | 内容 |
| --- | --- |
| 状态 | Accepted |
| 日期 | 2026-08-13 |
| 决策 | M0 服务返回“未配置”、权限“未申请”、动作记录为空，不内置伪成功数据 |
| 原因 | 产品要求失败、离线和权限不足都必须如实反馈 |
| 影响 | 后续 Preview 或 UI 测试数据必须与生产服务实现隔离并显式标注 |
