# 无硬件本地命令入口

> 日期：2026-10-22；依据：D-MAC-014。需求：无硬件独立软件验收与跨项目复用。

## 调用方式

`python3 MACsoftware/scripts/bridge_command.py [选项] <action> '<parameters JSON>'` 在仓库根目录执行。脚本从共享 Schema 取得 action/risk 对应关系，为每次调用生成新的 UUIDv7、随机 nonce 和短期时间戳，将命令交给 Swift CLI；它不直接操作系统。

| 选项 | 注册的能力 | 结果 mode |
| --- | --- | --- |
| 默认 | 真实 `system.volume.get` | `system_read_only` |
| `--allow-volume-control` | 真实 get/set/adjust | `system_volume_control` |
| `--simulate` | Debug 内存 get/set/adjust，初始音量 50 | `simulation` |
| `--paused` | 以上任一模式暂停执行 | 原模式，结果 rejected |

模拟与真实写入开关互斥。所有其他未实现能力返回 `capability_disabled`；不能因为 Schema 声明了 action 就认为适配器存在。Release 中 `--simulate` 拒绝初始化，退出码 2。

## 持续命令流与结果

直接运行 `swift run --package-path MACsoftware hushlight-bridge`，在 stdin 每行发送一个 `bridge-v1` `command.request` envelope。可参照 `scripts/bridge_cli_smoke.py` 生成有效样例；它覆盖模拟设置/读取、重放、未实现能力和非本地来源拒绝，不改变系统状态。

每行最多 65,536 字节，超限整行丢弃并返回 `payload_too_large`，下一行继续处理。允许 EOF 前最后一行无换行。不监听网络；只接受 `source.kind=debug_console`，device/cloud 返回 `unauthenticated`。CLI 另限制 `expires_at-issued_at ≤300 秒`，其余版本、参数、时间戳、nonce、风险和确认仍由共享核心校验。JSON 输出不回显输入参数。

结果是独立工具响应包装（不是远程 `BridgeEnvelope`）：包含 `mode`、`message_type` 和 `result`，协议失败时包含 `stable_error`；命令结果内部沿用 `CommandResult`。只有 `result.status=succeeded` 且 mode 为真实模式时，才能把结果当作真实系统成功。进程退出码 0 仅表示流正常处理，不表示每条命令成功。

音量的公共结果字段为 `summary.value`（0–100）。真实结果还含瞬时设备 ID、可读时的静音状态及 `evidence=core_audio_readback`；模拟结果含 `simulation=true` 与 `evidence=simulation`。工具适配方必须保留 mode/evidence，不能把模拟结果隐藏成真实成功。

## 重试、容量与信任

相同 nonce 拒绝重放；同 request_id 在结果缓存中时返回原结果，不再执行。定位为隐私例外：location.get 不写结果缓存，完成后同 ID 在有效期内拒绝重执行，不恢复旧位置；当前 CLI 未接生产定位。缓存最多 500 条或 7 天，已执行请求另保留至其原始有效期截止的准入记录；因此即使结果被淘汰，有效期内也不会重新执行。此时返回 `replay_detected`，不保证还能恢复原结果。准入记录与防重放记录各最多 4,096 条，满时以 `internal_error` 拒绝新执行，不淘汰活跃保护记录。

所有状态都只在当前进程内，重启或再次运行快捷脚本会清空。未来持久化服务、远程入口和消息发送不能据此宣称跨重启 exactly-once。调用方不应为未知结果自动换新 request_id 重试有副作用动作。

本机 OS 用户/进程权限构成 stdin 调用边界；debug_console 字段并不是网络鉴权。未来 Codex skill/MCP、语音识别或 iPhone 网关只能作为上层输入，继续调用同一核心；远程设备身份、配对和密钥另行实现。当前没有语音、手机联动、MCP server 或自动安装的 skill。

## 验收

命令：`swift test --package-path MACsoftware`、`swift build --package-path MACsoftware -c release`、`python3 MACsoftware/scripts/bridge_cli_smoke.py`。对照 MAC-AC-CLI-001～006 和 MAC-AC-SYS-001 的部分证据，结果见 `06_progress.md`。真实 set/adjust、多设备兼容、GUI 与设备集成单列待验。

## App 共用运行时（2026-10-22）

CLIEngine 现为兼容 facade，转发到 `BridgeLocalRuntime` 的 submit/setPaused/snapshot。CLI 参数、NDJSON 格式、结果包装和默认只读保持不变。App 的 LocalBridgeService 使用同一运行时实现，主窗口与菜单栏共享它；CLI 另起进程，暂停和缓存仍不与 App 共享。App 只读便捷接口先构造既有 system.volume.get 命令，再进统一处理链；没有新增 action。
