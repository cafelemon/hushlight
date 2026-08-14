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

## 2026-08-14：S1-W2 离线协议与执行内核（部分完成）

### 已实现

- 新增可打包的 `bridge-v1.schema.json`，覆盖 Envelope、Command、公共动作、风险等级和确认凭据外形。
- 新增 Swift 强类型协议模型、64 KiB 上限、版本/UUIDv7/时效/结构校验和设备鉴权字段检查。
- 新增按来源与 nonce 隔离的 `ReplayGuard`。
- 新增标准 Capability Registry、`PolicyEngine`、`CommandRouter` 和统一 `BridgeCommandProcessor`。
- 同一 `request_id` 的在途并发和完成后重试只执行一次适配器；结果缓存最多 500 条或 7 天。
- 暂停、风险不匹配、L3 缺少确认和未实现能力均在适配器执行前失败关闭。
- 适配器返回“成功但带错误”等矛盾结果时降为 `internal_error`；无法判断副作用的执行超时返回 `unknown`。

### 自动验证

- 本小节完成时 `swift test`：20 项测试，0 失败；同日后续增量见下一节的 32 项结果。
- 覆盖协议版本、UUIDv7 variant、过期、参数对象、鉴权字段、nonce 重放、Schema 资源、暂停、风险、L3 确认、能力关闭、并发幂等、完成结果缓存和统一处理入口。
- 构建环境：Apple Swift 6.3.3、Xcode 26.6；目标仍声明 macOS 13+。

### 当时证据边界（已由下一节部分补齐）

- 未实现 HMAC-SHA256 实际验签、错误密钥测试、配对限流、Keychain、Bonjour、WSS 或公钥固定。
- 当时 action 参数只要求 JSON object，逐 action Schema 已在下一节补齐。
- 当时 L3 只验证确认存在、动作、时效和设备来源；签名与完整绑定已在下一节补齐。
- 内存适配器只证明执行链和幂等，不代表真实设备、系统能力、网易云或微信验收。
- S1-W2 仍为部分完成，S1 Gate 未关闭。

### 下一开发入口

优先补齐逐 action 参数 Schema 与完整 L3 确认校验，再建立 Xcode `.app` target 和权限声明；Bonjour/WSS 可继续在没有设备时实现和做本机双端测试，但真实设备 Gate 保留待验。

## 2026-08-14：逐 action 参数与 L3 确认安全

### 已实现

- 为 17 个公共 action 建立 JSON Schema 和 Swift 双重参数约束，默认拒绝未知字段。
- 冻结音量绝对设置 `value` 与步进调整 `delta` 两个独立动作，消除协议与适配器文档歧义。
- `content.open` 在进入适配器前拒绝双目标、非 HTTPS、用户密码、IP 字面量、localhost 和 `.local` 主机；正式域名/Bundle ID 白名单仍由适配器配置执行。
- L3 确认绑定 Bridge、用户、设备、会话、provider、联系人和小写 SHA-256 草稿摘要，有效期最长 60 秒。
- 新增可替换 `ConfirmationVerifying` 接口和 HMAC-SHA256 阶段一参考实现；签名使用 canonical JSON claims。
- `CommandRouter` 在执行前原子占用确认 ID；不同 `request_id` 不能复用，已用确认最多保留 500 条或 7 天，容量异常失败关闭。

### 自动验证

- 本机 `swift test`：32 项测试，0 失败。
- 17-action 样例与 Capability Registry 数量对齐；Schema 中也包含 17 个 action 分支。
- 覆盖额外字段、数值越界、空更新、危险 URL、聊天目标歧义、错误摘要、签名篡改、声明变化、超时、设备不匹配和确认跨请求复用。
- 签名 `chat.send` 已通过 `BridgeCommandProcessor → ReplayGuard → CommandRouter → PolicyEngine → Adapter` 完整内存契约链。

### 证据边界

- HMAC 使用测试密钥和内存适配器，只证明协议与策略实现，不代表微信真实发送或云端签发完成。
- 云端正式密钥获取、轮换、撤销和确认签发接口仍待 O-MAC-004；不得把测试密钥写入 App。
- Bundle ID/HTTPS 最终白名单、系统 API 回读、真实权限和第三方应用状态仍需后续适配器与实机证据。
- LAN Envelope HMAC、配对和 WSS 尚未实现，S1 Gate 保持未通过。

### 下一开发入口

建立正式 Xcode `.app` target、Bundle ID 与权限声明；并行可实现不依赖真实设备的系统音量参数/回读抽象和本地计时器持久化内核。

## 外部待输入

| 输入 | Owner | 截止 Gate | 状态 |
| --- | --- | --- | --- |
| 设备侧 `bridge-v1`、WSS 和安全存储实现 | 设备固件 Owner | S1 Gate | 待指定/待实现 |
| 网易云安装包和冻结版本 | macOS/Test Owner | S1-W4 | 待提供 |
| 微信测试账号和测试联系人 | 产品/Test Owner | S1-W5 | 待提供 |
| 登录、WSS、确认凭据和测试环境 | 云端/Web Owner | S2 开始 | 待指定/待设计 |
| Apple Developer Program、证书、域名和更新源 | 项目负责人 | S3 开始 | 待提供 |
