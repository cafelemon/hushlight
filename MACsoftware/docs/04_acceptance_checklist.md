# Hushlight Mac 验收测试清单

> 文档版本：V0.4
> 更新日期：2026-08-14
> 规则：只有执行并保留证据后才能勾选；构建通过不等于实机、集成或发布验收通过。

## 1. M0 已有证据

- [x] `MACsoftware` 工程、SwiftPM 构建和文档骨架存在。
- [x] `swift build` 通过。
- [x] `swift test` 通过（32 项测试，0 失败；2026-08-14）。
- [x] 主窗口可启动并显示真实“未配置”、权限“未申请”和动作空状态。
- [ ] 菜单栏弹层与主窗口状态一致。
- [ ] 暂停/恢复 UI 交互通过；当前只有底层状态往返测试。
- [x] 未接真实云端、设备、网易云、微信或系统权限。

### 1.1 当前离线自动化证据

- 已覆盖：Schema 资源可解析、17 个 action 的严格参数约束、协议版本拒绝、UUIDv7 variant、过期拒绝、设备鉴权字段必填、nonce 重放拒绝、暂停拒绝、风险不匹配、能力失败关闭、并发/完成结果幂等和矛盾成功结果降级。
- L3 已覆盖：缺少确认、HMAC 签名篡改、最长 60 秒、Bridge/用户/设备/会话/provider/联系人/草稿绑定、设备来源不匹配，以及同一确认换 `request_id` 二次使用。
- 已证明 Debug 来源也必须进入 `BridgeCommandProcessor → ReplayGuard → CommandRouter → PolicyEngine → Adapter`，但尚未实现 Debug UI 和真实 Transport。
- 未覆盖：LAN Envelope 错误密钥、配对限流、WSS/证书固定、云端正式确认签发、真实设备、真实系统回读、第三方应用和发布矩阵。
- 因此 MAC-AC-LAN-005/006 与 MAC-AC-CHT-004 至 006 只有部分自动证据，不能勾选完整 Gate。

## 2. 协议和局域网 Gate

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-LAN-001 | Bonjour 发现 | 真实设备发现 `_hushlight-bridge._tcp`，无需手填 IP/端口 | 设备日志 + 录像 |
| MAC-AC-LAN-002 | 安全配对 | 配对码 5 分钟失效；错误码限流；成功后密钥进入 Keychain | 自动测试 + Keychain 检查 |
| MAC-AC-LAN-003 | WSS 与公钥固定 | 非固定证书、降级明文或中间人连接均失败 | 故障注入记录 |
| MAC-AC-LAN-004 | 本地网络权限 | macOS 15+ 允许、拒绝和恢复路径均可复现 | 三状态录像 |
| MAC-AC-LAN-005 | 防重放 | 过期、重复 nonce、错误密钥和已完成请求不产生新副作用 | 协议测试报告 |
| MAC-AC-LAN-006 | 同一执行链 | 真实设备与 Debug 测试台走相同 Decoder、Router、Policy 和 Adapter | 代码审查 + 契约测试 |
| MAC-AC-LAN-007 | Release 隔离 | Release 二进制无测试台入口、命令和调试凭据 | 构建产物检查 |

## 3. UI、权限和状态 Gate

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-UI-001 | 菜单栏和管理窗口 | 在线、暂停、权限和异常状态一致 | 状态矩阵 + 截图 |
| MAC-AC-UI-002 | Dock 开关 | 默认隐藏；用户切换并重启后生效；两种模式均可打开管理窗口 | 重启测试录像 |
| MAC-AC-UI-003 | 一键暂停 | 暂停后所有新动作在执行边界立即 `rejected` | 集成测试 |
| MAC-AC-UI-004 | 权限按需申请 | 未启用能力不提前申请；拒绝后有准确恢复路径 | 全新账户测试 |
| MAC-AC-UI-005 | 失败真实性 | 未配置、离线、权限缺失和未知结果均不显示成功 | 故障注入截图 |

## 4. 系统能力 Gate

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-SYS-001 | 系统音量 | 读取、绝对设置、步进调整后回读一致；边界值受控 | 自动测试 + 实机记录 |
| MAC-AC-SYS-002 | 本地计时器 | 创建、修改、取消、到时通知和应用重启恢复均通过 | 时间模拟 + 实机通知 |
| MAC-AC-SYS-003 | 提醒事项 | EventKit 创建、修改、取消通过；拒绝权限时不写入 | 测试提醒列表 + 日志 |
| MAC-AC-SYS-004 | 白名单打开 | 注册 Bundle ID 和 HTTPS 域名可打开；其他目标全部拒绝 | 白名单矩阵 |
| MAC-AC-SYS-005 | 通用媒体 | 播放、暂停、上一首和下一首返回可验证结果或 `unknown` | 重复测试 |

## 5. 网易云音乐 Gate

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-MUS-001 | 支持版本冻结 | 记录应用版本、macOS 版本、接入方式和稳定元素 | 支持版本表 |
| MAC-AC-MUS-002 | 搜索播放 | 指定查询播放正确结果或要求消歧 | 用例矩阵 + 录像 |
| MAC-AC-MUS-003 | 播放控制 | 播放、暂停、上一首和下一首重复执行稳定 | 至少各 20 次记录 |
| MAC-AC-MUS-004 | 状态回读 | 实际曲目/播放状态可验证；无法验证时为 `unknown` | 适配器日志 + 录像 |
| MAC-AC-MUS-005 | 版本失败关闭 | 未安装、未知版本或关键元素缺失时停止，不坐标点击 | 故障注入记录 |

## 6. 微信消息安全 Gate

以下任一项失败，S1 和 V0 均不得通过。

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-CHT-001 | 测试数据边界 | 只使用测试账号和测试联系人 | 账号清单 |
| MAC-AC-CHT-002 | 精确联系人 | 唯一匹配才能生成草稿；歧义和缺失停止 | 联系人矩阵 |
| MAC-AC-CHT-003 | 草稿无外部影响 | `chat.draft` 只填入内容，发送数为 0 | 屏幕录像 + 测试记录 |
| MAC-AC-CHT-004 | 明确确认 | 复述联系人和完整内容后才取得短时确认凭据 | 端到端录像 |
| MAC-AC-CHT-005 | 确认失效 | 草稿/联系人变化、超时、断线和应用未知均使旧确认失效 | 故障注入 |
| MAC-AC-CHT-006 | 幂等发送 | 重复 `request_id` 不重复发送 | 重放测试 |
| MAC-AC-CHT-007 | 真实结果 | 发送无法验证时返回 `unknown`，不得报成功 | 适配器日志 |
| MAC-AC-CHT-008 | 未确认发送 | 总数为 0 | 红队报告 |

## 7. 云端完整闭环 Gate

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-CLD-001 | 登录绑定 | Web 登录自动绑定账户、设备和 Bridge，不手填配置 | 全新账户录像 |
| MAC-AC-CLD-002 | 出站 WSS | Bridge 不开放公网入站；令牌过期可刷新或明确下线 | 网络记录 + 日志 |
| MAC-AC-CLD-003 | 能力快照 | 云端看到版本、权限、暂停和适配器能力，不接收敏感正文 | Payload 检查 |
| MAC-AC-CLD-004 | 重连 | 网络恢复后自动重连，不重放过期或 L3 请求 | 断网测试 |
| MAC-AC-CLD-005 | 端到端结果 | 设备只播报 Bridge 最终结果，不能把 ack 当成功 | 全链路录像 |
| MAC-AC-CLD-006 | Bridge 降级 | Bridge 离线时基础聊天可用，本地动作明确不可用 | 断连录像 |

## 8. 日志、稳定性和发布 Gate

| ID | 验收项 | 通过条件 | 证据 |
| --- | --- | --- | --- |
| MAC-AC-LOG-001 | 动作记录 | 最多 500 条或 7 天，无联系人、正文、令牌和敏感路径 | 数据内容检查 |
| MAC-AC-LOG-002 | 诊断包 | 最多 20 MB 或 7 天，默认脱敏且可由用户导出 | 包内容审计 |
| MAC-AC-STB-001 | 长稳 | 连续 8 小时、至少 50 次动作循环，无非预期重启或状态卡死 | 长稳日志 |
| MAC-AC-REL-001 | 签名公证 | Developer ID、Hardened Runtime、secure timestamp、notary 和 staple 通过 | 签名与公证日志 |
| MAC-AC-REL-002 | DMG | 全新 Mac 无需终端即可安装、启动、退出和卸载 | 平台录像 |
| MAC-AC-REL-003 | 登录项 | 用户选择后注册；关闭后 `SMAppService` 不再启用 | 系统设置检查 |
| MAC-AC-REL-004 | 安全更新 | EdDSA 验证；篡改包拒绝；灰度渠道可控 | 更新测试 |
| MAC-AC-REL-005 | 更新回滚 | 失败恢复上一版本；不恢复待执行 L3 请求 | 故障注入 |
| MAC-AC-REL-006 | 系统矩阵 | 最低支持版本、上一主流版本和当前 macOS 均通过核心回归 | 版本矩阵 |
| MAC-AC-REL-007 | 发布证据 | 版本匹配的代码、安全和发布就绪评估通过 | 审查记录 |

## 9. 需求追踪矩阵

本表是“需求—协议/实现点—阶段—验收”唯一追踪入口。修改需求、动作名、阶段或验收项时必须在同一变更中更新本表；仅在表中出现不代表已经验收通过。

| 需求 ID | 协议或实现点 | 阶段 | 验收 ID |
| --- | --- | --- | --- |
| MAC-FR-001 | 状态快照、菜单栏和管理窗口 | S1 | MAC-AC-UI-001 |
| MAC-FR-002 | 权限快照、脱敏动作记录和恢复路径 | S1 | MAC-AC-UI-001、MAC-AC-UI-004、MAC-AC-UI-005 |
| MAC-FR-003 | Dock activation policy 持久化 | S1 | MAC-AC-UI-002 |
| MAC-FR-004 | `PolicyEngine` 暂停执行边界 | S1 | MAC-AC-UI-003 |
| MAC-FR-005 | `bridge-v1` Decoder、Router、Policy 和 Adapter | S1 | MAC-AC-LAN-006、MAC-AC-LAN-007 |
| MAC-FR-006 | Bonjour、WSS、配对、HMAC 和防重放 | S1 | MAC-AC-LAN-001 至 MAC-AC-LAN-005 |
| MAC-FR-007 | Cloud Transport、令牌刷新和 L3 禁止重放 | S2 | MAC-AC-CLD-001 至 MAC-AC-CLD-006 |
| MAC-FR-008 | `system.volume.get/set/adjust` | S1 | MAC-AC-SYS-001 |
| MAC-FR-009 | `timer.create/update/cancel` | S1 | MAC-AC-SYS-002 |
| MAC-FR-010 | `reminder.create/update/cancel` | S1 | MAC-AC-SYS-003 |
| MAC-FR-011 | `content.open` 与 Bundle ID/HTTPS 白名单 | S1 | MAC-AC-SYS-004 |
| MAC-FR-012 | `media.play/pause/previous/next` | S1 | MAC-AC-SYS-005 |
| MAC-FR-013 | `music.search_and_play` 与网易云适配器 | S1 | MAC-AC-MUS-001 至 MAC-AC-MUS-005 |
| MAC-FR-014 | `chat.draft`、精确联系人和草稿摘要 | S1 | MAC-AC-CHT-001 至 MAC-AC-CHT-003 |
| MAC-FR-015 | `chat.send`、确认凭据和请求幂等 | S1/S2 | MAC-AC-CHT-004 至 MAC-AC-CHT-008、MAC-AC-CLD-004、MAC-AC-CLD-005 |
| MAC-FR-016 | 脱敏动作元数据和保留上限 | S1 | MAC-AC-LOG-001 |
| MAC-FR-017 | 脱敏诊断滚动与导出 | S1 | MAC-AC-LOG-002 |
| MAC-FR-018 | Developer ID DMG、公证、更新、回滚和卸载 | S3 | MAC-AC-REL-001 至 MAC-AC-REL-007 |

跨能力非功能要求由 MAC-AC-STB-001 覆盖；阶段二必须对全部 S1 验收项执行同 Transport 契约回归。

## 10. 当前验收结论

当前仅 M0 构建、两项单元测试和主窗口空状态有证据。所有 S1、S2、S3 项均为待实现、待测试，不代表用户验收或生产验收通过。
