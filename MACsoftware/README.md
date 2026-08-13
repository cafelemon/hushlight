# Hushlight Mac

小熙 macOS PC Bridge 主线。当前为 M0 工程骨架，包含菜单栏入口、主状态窗口、权限与最近动作占位、服务协议和基础测试。

## 环境

- macOS 13+
- Swift 6+
- Xcode 16+

## 本地验证

```bash
swift build
swift test
swift run HushlightMac
```

`swift run` 仅用于开发预览。正式 `.app`、签名、公证、更新和卸载从 M1 开始建设。

## 当前边界

- 未连接云端、桌面设备、网易云音乐或微信。
- 未申请麦克风、辅助功能、自动化等系统权限。
- 界面中的“未配置”与空记录是真实状态，不代表集成已经完成。

文档入口见 [`docs/00_overview.md`](docs/00_overview.md)。
