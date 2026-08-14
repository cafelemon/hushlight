# Hushlight Bridge V1 协议规格

> 协议名：`bridge-v1`
> 版本：`1.0`
> 更新日期：2026-08-14
> 状态：实现中；逐 action Schema 与 L3 确认参考实现已建立，Transport 与 LAN 鉴权待实现

## 1. 目标和消费者

`bridge-v1` 统一 macOS、Windows、设备和云端对本地动作、风险、确认、幂等和结果的理解。LAN、Cloud 和后续 MCP 网关只能运输或转换该协议，不得拥有另一套动作语义。

| 角色 | 责任 |
| --- | --- |
| 设备 | 阶段一提交请求、接收 ack/结果、展示或播报结果 |
| 云端 | 阶段二生成请求、L3 确认凭据和能力策略 |
| Bridge | 验证、拒绝或执行，产生最终结果 |
| Windows/macOS | 共享动作名、参数、错误和结果；本地实现可不同 |
| MCP 网关 | 后续将 MCP 调用转换为 `bridge-v1`，不直连适配器 |

## 2. 传输和消息类型

- 编码：UTF-8 JSON，每个 WebSocket message 只包含一个 envelope。
- LAN：Bonjour `_hushlight-bridge._tcp` + WSS + 公钥固定。
- Cloud：Bridge 主动建立 WSS。
- 单条消息上限：64 KiB；超过时以 `payload_too_large` 拒绝。

| `message_type` | 方向 | 用途 |
| --- | --- | --- |
| `hello` | 双向 | 协议、平台、应用和设备版本协商 |
| `heartbeat` | 双向 | 活性和时钟偏差检测 |
| `capability.snapshot` | Bridge→设备/云端 | 工具、权限、暂停、适配器和支持版本 |
| `command.request` | 设备/云端→Bridge | 提交动作 |
| `command.ack` | Bridge→来源 | 只确认收到和进入处理 |
| `command.result` | Bridge→来源 | 返回唯一最终结果 |
| `pair.begin` | 设备→Bridge | 阶段一发起配对 |
| `pair.complete` | 双向 | 固定公钥并建立设备密钥 |
| `error` | 双向 | 消息级协议错误，不代表工具结果 |

## 3. 通用 Envelope

```json
{
  "protocol_version": "1.0",
  "message_type": "command.request",
  "message_id": "018f0f4e-2f55-7f5c-9ca2-111111111111",
  "request_id": "018f0f4e-2f55-7f5c-9ca2-222222222222",
  "source": {
    "kind": "device",
    "id": "h0-reference-01"
  },
  "issued_at": "2026-08-13T06:00:00Z",
  "expires_at": "2026-08-13T06:00:30Z",
  "nonce": "base64url-random",
  "auth": {
    "key_id": "paired-device-key-01",
    "mac": "base64url-hmac-sha256"
  },
  "payload": {}
}
```

| 字段 | 规则 |
| --- | --- |
| `protocol_version` | 必填；仅接受显式支持版本 |
| `message_id` | 每条消息唯一，UUIDv7 |
| `request_id` | command 全生命周期稳定，UUIDv7 |
| `source.kind` | `device / cloud / debug_console` |
| `source.id` | 已配对设备、云端租户或 Debug 会话标识 |
| `issued_at` / `expires_at` | RFC 3339 UTC；过期立即拒绝 |
| `nonce` | 每个来源在有效窗口内唯一 |
| `auth` | LAN 使用配对密钥对规范化 envelope 计算 HMAC-SHA256；Cloud 使用已鉴权 WSS 会话并保留会话标识 |
| `payload` | 由 `message_type` 对应 Schema 校验 |

接收端必须拒绝未知 `message_type`、不支持版本、缺失必填、超限、过期、未来时间异常、重复 nonce 和未鉴权来源。

## 4. Command Request

```json
{
  "action": "music.search_and_play",
  "risk_level": "L2",
  "parameters": {
    "provider": "netease_music",
    "query": "轻松的歌"
  },
  "confirmation": null
}
```

| 字段 | 规则 |
| --- | --- |
| `action` | 必须存在于本地 Capability Registry |
| `risk_level` | 请求值只用于一致性检查，不能降低本地注册风险 |
| `parameters` | 按 action 的独立 Schema 严格校验 |
| `confirmation` | L3 必填；L0–L2 必须为空 |

所有参数对象默认拒绝未知字段。标识最长 128 字符并限制为 ASCII 字母、数字、`.`、`_`、`:`、`-`；展示文本拒绝空白并设置动作级长度上限。精确字段以 JSON Schema 与 `09_local_adapter_spec.md` 为准。

公共动作集：

| Action | 风险 | 适配器 |
| --- | --- | --- |
| `system.volume.get` | L0 | System Volume |
| `system.volume.set` | L1 | System Volume |
| `system.volume.adjust` | L1 | System Volume |
| `timer.create/update/cancel` | L2 | Local Timer |
| `reminder.create/update/cancel` | L2 | EventKit Reminder |
| `content.open` | L1 | Content Open |
| `media.play/pause/previous/next` | L1 | Media |
| `music.search_and_play` | L2 | Music provider |
| `chat.draft` | L2 | Chat provider |
| `chat.send` | L3 | Chat provider |

## 5. Ack 与最终结果

`command.ack`：

```json
{
  "request_id": "018f0f4e-2f55-7f5c-9ca2-222222222222",
  "accepted_at": "2026-08-13T06:00:01Z"
}
```

Ack 不包含 `status: succeeded`，也不能被设备播报为完成。

`command.result`：

```json
{
  "request_id": "018f0f4e-2f55-7f5c-9ca2-222222222222",
  "action": "music.search_and_play",
  "status": "succeeded",
  "stable_error": null,
  "summary": {
    "provider": "netease_music",
    "playback_state": "playing",
    "track_title": "已验证曲目标题"
  },
  "completed_at": "2026-08-13T06:00:04Z"
}
```

| `status` | 语义 |
| --- | --- |
| `succeeded` | 副作用和成功证据均已验证 |
| `failed` | 已尝试但确定失败 |
| `rejected` | 策略、权限、参数、版本或确认不允许执行 |
| `unknown` | 已尝试但无法确认最终外部状态 |

每个 `request_id` 只产生一个最终结果。重复请求返回已保存结果；若仍在处理，返回相同 ack，不启动第二次执行。

## 6. 稳定错误码

| 错误码 | 结果 | 适用 |
| --- | --- | --- |
| `unsupported_protocol` | rejected | 协议版本不支持 |
| `invalid_schema` | rejected | 消息或参数不合法 |
| `payload_too_large` | rejected | 消息超过 64 KiB |
| `unauthenticated` | rejected | 未配对或令牌无效 |
| `request_expired` | rejected | 已超过有效期 |
| `replay_detected` | rejected | nonce 或签名重放 |
| `bridge_paused` | rejected | 用户已暂停 |
| `permission_required` | rejected | 系统权限缺失 |
| `capability_disabled` | rejected | 本地或云端停用 |
| `app_not_installed` | failed | 目标应用不存在 |
| `app_version_unsupported` | rejected | 版本不在支持矩阵 |
| `target_ambiguous` | rejected | 联系人或内容不唯一 |
| `confirmation_required` | rejected | L3 无有效确认 |
| `confirmation_expired` | rejected | 确认过期或失效 |
| `confirmation_invalid` | rejected | 签名、声明或绑定字段无效 |
| `confirmation_used` | rejected | 确认 ID 已被其他请求占用 |
| `execution_timeout` | failed/unknown | 适配器超时，按是否可能产生副作用决定 |
| `result_unverifiable` | unknown | 无法取得可靠成功证据 |
| `internal_error` | failed | 内部错误，不暴露敏感细节 |

错误码语义在 V1 内不可改变；新增错误码必须允许旧消费者按 `failed/rejected/unknown` 上层状态处理。

## 7. L3 确认凭据

`chat.send` 的 `confirmation` 绑定：

- 用户、设备、Bridge 和会话标识。
- `action`、聊天 provider、联系人稳定标识。
- 完整草稿规范化后的 SHA-256 摘要。
- 签发时间、过期时间和唯一确认 ID。
- 单次使用标志和签发方签名。

确认字段固定为 `confirmation_id/action/issued_at/expires_at/user_id/device_id/bridge_id/session_id/provider/target_id/draft_sha256/key_id/signature`。有效期最长 60 秒；SHA-256 使用 64 位小写十六进制；签名输入为移除 `key_id/signature` 后按键排序、ISO 8601 日期编码的 canonical JSON claims。

阶段一参考实现使用 256 位 HMAC-SHA256 密钥和 base64url 无填充签名，通过 `ConfirmationVerifying` 接口注入。阶段二由云端策略在用户明确确认后签发；正式密钥取得、轮换和签发接口仍由云端/Web Owner 冻结，但必须验证相同 claims 语义或通过新 ADR 升级协议。

Bridge 在调用适配器前原子占用 `confirmation_id`。相同 `request_id` 返回幂等结果；不同 `request_id` 复用同一确认返回 `confirmation_used`。已用确认最多保留 500 条或 7 天，存储满时失败关闭。签名、绑定字段、有效期或使用状态任一不符均不得调用适配器。

## 8. 配对和传输安全

- Bridge 生成自签名 TLS 身份并在 Keychain 保存私钥。
- 设备通过 5 分钟一次性配对码建立会话并固定 Bridge 公钥指纹。
- 配对连续失败 5 次后锁定 10 分钟；重新生成配对码会使旧码失效。
- 配对成功后双方生成或交换 256 位随机设备密钥；后续 LAN 消息使用该密钥的 `key_id` 和 HMAC-SHA256 鉴权。
- 不允许 WSS 降级为明文 WebSocket；证书、公钥或设备密钥不匹配时停止。
- 注销、解绑或用户清除本地数据后删除对应配对密钥。

## 9. 能力快照

能力快照包含：Bridge/协议版本、平台、暂停状态、权限状态、每个 action 的启停、风险、适配器 provider 和支持应用版本。不得包含联系人、消息正文、令牌或本地路径。

## 10. 兼容策略

- V1 可新增默认可忽略的可选字段。
- 删除字段、改变含义、增加必填、改变枚举语义或改变风险等级必须发布新协议版本。
- Bridge 同时支持新旧版本的窗口由阶段发布计划定义；未知版本默认拒绝。
- JSON Schema、Swift 类型、设备类型和 Windows 类型必须通过同一组契约样例。
- MCP 网关输出合法 `bridge-v1 command.request`，并接收同一 `command.result`；不得定义旁路成功语义。

当前 Schema 文件位于 `Sources/HushlightMac/Resources/bridge-v1.schema.json`，Swift 入口位于 `BridgeProtocolValidator` 和 `BridgeCommandProcessor`。17 个公共 action 的参数、风险和确认要求已进入 Schema 与运行时校验；L3 HMAC 参考实现位于 `ConfirmationSecurity.swift`。LAN Envelope HMAC、配对密钥和云端正式签发接口仍待实现。

## 11. 必测协议场景

- 正常 hello、心跳、能力快照、请求、ack 和结果。
- 未知版本、未知消息、超限和 Schema 错误。
- 过期、未来时间、重复 nonce、重复 request 和错误密钥。
- 暂停、权限缺失、能力停用、应用缺失和版本不兼容。
- L3 无确认、错误绑定、草稿变化、超时、断线和重复发送。
- LAN 与 Cloud 输入相同请求时结果语义一致。
