# Hushlight Mac

小熙 macOS PC Bridge 主线。当前包含 M0 状态壳，以及 S1-W2 的离线协议内核：`bridge-v1` 类型/逐 action Schema、统一命令处理入口、策略引擎、防重放、结果幂等和 L3 确认参考实现。

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

`swift run` 仅用于开发预览。阶段一先建立用于权限验证的 Xcode `.app`；正式签名、公证、更新、回滚和卸载在 S3 建设。

## 当前边界

- 未连接云端、桌面设备、网易云音乐或微信。
- 尚未实现 Bonjour/WSS、配对密钥、LAN Envelope HMAC 验签和真实适配器；L3 HMAC 确认测试不代表安全配对通过。
- 未申请麦克风、辅助功能、自动化等系统权限。
- 界面中的“未配置”与空记录是真实状态，不代表集成已经完成。

## 文档

- [`docs/00_overview.md`](docs/00_overview.md)：项目总览与三阶段主线
- [`docs/01_prd.md`](docs/01_prd.md)：产品边界、旅程和需求
- [`docs/02_roadmap.md`](docs/02_roadmap.md)：工作包、周期和 Gate
- [`docs/03_architecture.md`](docs/03_architecture.md)：LAN/Cloud 双 Transport 与执行架构
- [`docs/04_acceptance_checklist.md`](docs/04_acceptance_checklist.md)：分阶段验收矩阵
- [`docs/08_bridge_protocol.md`](docs/08_bridge_protocol.md)：`bridge-v1` 协议规格
- [`docs/09_local_adapter_spec.md`](docs/09_local_adapter_spec.md)：系统、网易云和微信适配器规格
