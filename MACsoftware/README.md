# Orbit 智轨 · Agent 工作台

## 当前进度（2026-10-24）

通用Mac能力工作台，支持本机手动操作与独立授权的Agent接入。最新增加QQ聊天只读预览，QQ7.0.2原生读回已通过，GUI展示仍待验收；QQ聊天发送、自动回复及对应MCP工具尚未接入。微信暂停，网易云跳过。现有计时器、提醒、备忘录、天气/位置、Apple Mail、日历、QQ音乐与语音等能力的具体实机边界见[进度](docs/06_progress.md)。

最新检查：463项测试，452通过、11按条件跳过、0失败；Release构建通过。私钥、配对凭据、账号状态、原始日志和聊天图像不随源码发布；[公开验证说明](evidence/README.md)解释本地证据边界。以下日期记录保留实现历史，当前状态以上述说明和最新进度为准。


## 2026-10-24 可选窗口识别

新版固定签名App包含「语音输入」及「窗口识别」。窗口识别需用户首次允许屏幕录制（macOS14.2+），先选QQ/微信窗口取得预览，再手动框选区域给本机Vision；不保存截图、不发送模型、不自动点击/输入/发送。首次实窗验收尚待完成，合成图通过不能代替。见[本轮证据](evidence/2026-10-24-window-vision/README.md)。

## 当前推荐入口（2026-10-24）

使用固定签名、固定位置的 `~/Applications/Agent Workbench Dev.app`。先退出正在运行的开发包，再执行 `python3 MACsoftware/scripts/build_dev_app.py --signed --install`；本机签名配置需先按 `docs/13_automation_workbench.md` 的独立验证流程建立。Bundle ID 和已有数据位置不变，构建不会授予系统权限或 Agent 授权。

Codex MCP 指向该 App 内的 `Contents/MacOS/agent-workbench-mcp`，复用原凭据文件。更新后刷新 MCP 连接以发现已授权工具；QQ 新授权默认关闭。下文旧的 `.build/HushlightMac-Dev.app` / ad-hoc 示例保留开发历史，不作为当前权限复用验收入口。当前功能与实机状态以 [进度](docs/06_progress.md) 和 [统一验收](docs/12_integrated_acceptance.md) 为准。

2026-10-23 后续：后台 Codex 超时已修复，真实 Swift 合成结构化调用通过。全套 253 项、0 fail（1 条 opt-in 按设计跳过），Release 通过。仅分析通道通过，实际邮箱联动与系统授权更新复用仍待验。[最新证据](evidence/2026-10-23-codex-proxy/README.md)。

2026-10-23：新增权限静默复用和联动中心首版，含早间天气、增量邮件分析/草稿、专用日历/提醒、每日摘要和 Agent 分析租约。242 项测试及 Release 通过；真实 Codex 合成调用超时，系统联动与 TCC 跨重建保留尚待统一验收。固定签名候选 `/Users/example/Applications/Agent Workbench Dev.app` 尚未切换为运行中的主入口。详见 [实现/限制](docs/13_automation_workbench.md) 和 [验证记录](evidence/2026-10-23-automation/README.md)。

小熙 macOS PC Bridge 与可复用本机执行核心。无需硬件即可开发、测试和调用：独立 `BridgeCore` library 提供统一校验、策略和路由；`hushlight-bridge` CLI 接收本地命令，当前支持音量模拟和 Core Audio 真实音量回读/控制。SwiftUI App 已接入真实本地服务，提供只读音量、暂停恢复与真实动作记录。

## 当前版本：通用 Agent 工作台（2026-10-23）

主窗口分为总览、Agent 接入、系统音量、计时器、提醒事项、备忘录、天气、定位、权限与设置、执行记录。小熙与 Codex 均为调用方；现有 Bundle ID、存储位置和已连接的列表/文件夹不变。

App 持有唯一 LocalBridgeService 和 WorkbenchHost。新增 `agent-workbench-mcp` 通过 STDIO 与客户端通信，通过当前用户 Unix Socket 调用 App；新连接默认无能力授权，读写与定位分别开启，随时可撤销。主窗口、菜单栏与 MCP 共用暂停状态。旧 `hushlight-bridge` 仍是独立调试入口。

运行 `python3 MACsoftware/scripts/build_dev_app.py` 构建开发包，其中包含 App 与 MCP helper。在“Agent 接入”创建连接、保存授权、复制 Codex 配置；配置引用凭据文件，不包含凭据内容。接入说明和可复用 skill 见 [integrations/README.md](integrations/README.md)。App 关闭时 MCP 返回不可用，不启动备用运行时。

每个写工具必须使用固定 UUID `request_id`。未知结果先用 `workbench_result` 核对，不能改 ID 盲目重试。去重账本只保存元数据/摘要；满 10,000 笔停止新写入，核对待定结果后撤销旧连接可回收空间；撤销后的审计摘要单独保留最近 1,000 笔。正文和坐标不落入该账本。

以下按日期保留的记录是历史证据；当前能力和剩余实机验收以 [最新进度](docs/06_progress.md) 与 [统一清单](docs/12_integrated_acceptance.md) 为准。

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

## 无硬件命令入口

在仓库根目录执行（需要 Swift 和 Python 3，无额外依赖）：

```bash
# 真实读取默认输出音量；不改变系统状态
python3 MACsoftware/scripts/bridge_command.py system.volume.get

# Debug 模拟命令，明确返回 mode=simulation，不改变系统音量
python3 MACsoftware/scripts/bridge_command.py --simulate system.volume.set '{"value":35}'

# 暂停模式验证拒绝
python3 MACsoftware/scripts/bridge_command.py --simulate --paused system.volume.get
```

显式启用真实控制后可调用 set/adjust。例如下列命令会调低当前默认输出设备音量：

```bash
python3 MACsoftware/scripts/bridge_command.py --allow-volume-control system.volume.adjust '{"delta":-5}'
```

不支持主音量控制的设备会明确失败。真实写入后必须回读；无法验证返回 `unknown`，不会报告成功。此次仅做真实读取，未改变开发机音量。

长驻工具通过 `swift run --package-path MACsoftware hushlight-bridge [选项]` 向 stdin 连续提交 NDJSON，stdout 每行一个 JSON 结果。Python 快捷脚本每次启动新进程，只适合单次调用；持续状态和幂等测试使用同一个 CLI 进程。`--help` 查看参数。完整调用与信任边界见 [10_local_command_runner.md](docs/10_local_command_runner.md)。

## 持久化计时器（2026-10-22）

开发 App 已加入计时器创建、修改、取消、列表和按需通知授权。期望状态原子保存，重启恢复未来任务；过期不补发。通知权限撤销后仍可保存取消意图。暂停只拒绝新命令，已安排的系统通知继续生效。

先退出旧开发包，再运行 `python3 MACsoftware/scripts/build_dev_app.py`，生成 `.build/HushlightMac-Dev.app`；脚本只构建，不启动或授权。CLI 默认仍只有音量能力，不能用它冒充系统通知验收。

常规测试 80 项通过、1 项真实音量按需跳过；系统通知授权/到时显示与窗口/菜单栏仍因原生 UI 通道 timeout/pipeclosed 待验。详见 [计时器进度](docs/06_progress.md) 和 [本轮证据](evidence/2026-10-22-timers/)。

## App 接入真实核心（2026-10-22）

App 与 CLI 复用 `BridgeLocalRuntime` 实现；主窗口与菜单栏共享一个 `AppModel` 和服务实例。App 默认只读，不提供音量写入按钮，不申请新权限。状态“本地可用”指执行核心已就绪，云端与设备仍未连接；当前设备是否支持音量读取以实际结果为准。暂停选择保存至本地偏好，重启恢复。CLI 的启动参数和独立进程行为保持不变，尚未实现跨进程统一暂停。

常规测试 60 项通过、1 项真实音量测试默认跳过；启用 `HUSHLIGHT_LIVE_VOLUME_SMOKE=1` 单独运行该烟测通过。Release 构建与 CLI 模拟烟测通过。证据见 [App runtime 记录](evidence/2026-10-22-app-runtime/)。原生 UI 工具两次报 `Sky Computer Use native pipe closed before response`，窗口/菜单栏的手工验收仍待完成，不以自动测试代替。

## 首轮验证

2026-10-22：48 项测试通过、Release 构建通过、模拟烟测通过、真实音量读取成功。默认写入拒绝、暂停拒绝和 Release 模拟拒绝均通过。记录见 [evidence/2026-10-22](evidence/2026-10-22/)。真实写入、不同音频设备、GUI 手工验收、联网和第三方应用仍待验收。

## 当前边界

- 未连接云端、桌面设备、网易云音乐或微信。
- 尚未实现设备 Bonjour/WSS、设备配对密钥或 LAN Envelope HMAC 验签；本机 Agent 凭据不代表设备安全配对通过。
- 辅助功能用于 QQ 播放栏；Mac 语音输入按明确点击申请麦克风和语音识别权限。通知、提醒事项、备忘录自动化及定位仍按需申请并复用，真实验收分别记录。
- App 展示本地核心状态和实际动作结果；云端、设备与第三方应用尚未连接，不代表集成已经完成。
- CLI 仅接受本机 `debug_console` 来源，不监听网络，不认证或接纳设备/云端身份。模拟实现只在 Debug 编译，不打包进入用户 App。

## 整体规划

[Mac Bridge 整体能力与交付规划](docs/11_mac_bridge_master_plan.md)：先原生能力与本地工具复用，再音乐/微信，后语音和 iPhone；邮箱首版已确定 Apple Mail。该文档是待评审规划，新增功能尚未实现。

## 文档

- [`docs/00_overview.md`](docs/00_overview.md)：项目总览与三阶段主线
- [`docs/01_prd.md`](docs/01_prd.md)：产品边界、旅程和需求
- [`docs/02_roadmap.md`](docs/02_roadmap.md)：工作包、周期和 Gate
- [`docs/03_architecture.md`](docs/03_architecture.md)：LAN/Cloud 双 Transport 与执行架构
- [`docs/04_acceptance_checklist.md`](docs/04_acceptance_checklist.md)：分阶段验收矩阵
- [`docs/08_bridge_protocol.md`](docs/08_bridge_protocol.md)：`bridge-v1` 协议规格
- [`docs/09_local_adapter_spec.md`](docs/09_local_adapter_spec.md)：系统、网易云和微信适配器规格


## 提醒事项开发包

运行 `python3 MACsoftware/scripts/build_dev_app.py` 生成 `.build/HushlightMac-Dev.app`（临时 ad-hoc 签名）。提醒事项必须在这个 App 中明确点击启用，才申请系统权限并创建“小熙”专用列表；只管理带 Bridge 标记的条目。SwiftPM 裸可执行文件与测试不能申请真实提醒事项权限。新提醒事项功能尚待实机验收；CLI 当前仍不注入 EventKit 后端。


## 备忘录开发包（1.2）

新版开发 App 提供“连接备忘录并启用专用文件夹”。每次启动需明确连接，首次会申请 Apple Notes 自动化权限，在默认账户创建专用“小熙 Bridge”文件夹。查询仅按标题，支持纯文本读取、创建和追加本工具创建且未外改的笔记；不支持任意富文本改写、附件或删除。旧同名文件夹不自动收编。出现不确定写入时，用“重新连接并核对待定写入”回读，不要重复创建/追加。真实系统读写待手工验收，测试用 fake 和无 Notes handler 的传输 stub。


## 指定城市天气（1.3）

App 提供 12 个预设城市的当前时段模式预报与未来 12 小时，数据来源 MET Norway，按 CC BY 4.0 署名。只在点击查询时联网，不申请定位。显示模式更新时间、获取时间、城市时区及缓存状态；联网失败或数据核对失败会明确返回错误，不把过期结果冒充成功。

按照用户最新安排，Notes、天气与后续功能的真实应用/网络/权限项目统一执行 [统一验收清单](docs/12_integrated_acceptance.md)，开发阶段继续自动测试和构建。当前没有把真实联网验收写为通过。


## 按需大致定位（1.4）

App 提供单独的“检查并申请定位权限”和“获取一次大致位置”，启动不创建定位管理器或采样；只在明确点击且已授权时调用 Core Location 的一次定位。坐标保留两位小数、报告精度至少 1500m，并显示采样时间/来源；成功、失败、超时或取消都停止请求。可清除显示，结果不写命令缓存，不落盘轨迹，也不会自动发给天气。真实 macOS 授权及定位效果纳入统一验收，本轮只运行 fake 测试。CLI 没有注入生产定位后端。
