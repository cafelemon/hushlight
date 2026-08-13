# Hushlight Mac 进度记录

## 2026-08-13：M0 工程骨架

### 已验证

- 建立 `MACsoftware` 独立目录和 SwiftPM 工程。
- 建立 SwiftUI 主窗口、菜单栏入口、Bridge 状态/权限/动作结果模型和占位服务。
- Swift 6 构建通过。
- 2 项单元测试通过，0 失败。
- 本机启动主窗口并确认“未配置”、权限“未申请”和动作空状态按设计显示。

### 未验证

- 菜单栏弹层与主窗口状态一致性。
- 暂停/恢复 UI 交互；当前只有底层状态往返测试。
- Xcode App target、系统权限、真实设备、云端、网易云、微信和正式安装包均未实现。

## 2026-08-13：开发地图和架构收敛

### 已完成文档决策

- Mac 主线改为局域网研发闭环、云端完整闭环、正式产品准备三个阶段。
- 冻结纯 Bridge、菜单栏 + 管理窗口、可选 Dock、Debug 测试台边界。
- 冻结阶段一全部本地能力和阶段二云端长连接范围。
- 冻结 `com.hushlight.bridge.mac`、`bridge-v1`、Bonjour + WSS + 配对密钥。
- 冻结官网 Developer ID DMG 和 Sparkle `2.9.4` 方向。
- 建立 `08_bridge_protocol.md` 和 `09_local_adapter_spec.md`。

### 证据边界

以上仅代表规划和设计已经形成文档基线，不代表 S1/S2/S3 功能开发、实机验收、第三方应用兼容、签名、公证或发布已经完成。

### 下一开发入口

按 `02_roadmap.md` 从 S1-W1 开始：建立 Xcode `.app` target、固定 Bundle ID、Development signing、权限声明和菜单栏/窗口/Dock 行为。进入编码前先评审 `08_bridge_protocol.md` 的设备实现可行性。

## 外部待输入

| 输入 | Owner | 截止 Gate | 状态 |
| --- | --- | --- | --- |
| 设备侧 `bridge-v1`、WSS 和安全存储实现 | 设备固件 Owner | S1 Gate | 待指定/待实现 |
| 网易云安装包和冻结版本 | macOS/Test Owner | S1-W4 | 待提供 |
| 微信测试账号和测试联系人 | 产品/Test Owner | S1-W5 | 待提供 |
| 登录、WSS、确认凭据和测试环境 | 云端/Web Owner | S2 开始 | 待指定/待设计 |
| Apple Developer Program、证书、域名和更新源 | 项目负责人 | S3 开始 | 待提供 |
