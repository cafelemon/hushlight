# Hushlight Mac 本地适配器功能规格

> 版本：V1.1
> 更新日期：2026-08-14
> 状态：参数契约已实现；真实适配器均尚未实现

## 1. 通用契约

每个适配器必须声明 provider、支持应用 Bundle ID/版本、动作、风险、所需权限、参数 Schema、执行前条件、成功证据、超时和停用条件。

统一执行顺序：参数校验 → 暂停/权限/版本/白名单/确认校验 → 执行 → 回读 → 归一结果。适配器不得直接建立 LAN/Cloud 连接、签发确认或修改公共协议。

参数对象严格拒绝未知字段；内部 ID 只允许 ASCII 字母、数字、`.`、`_`、`:`、`-`，最长 128 字符。日期使用 RFC 3339，SHA-256 使用 64 位小写十六进制。Schema 和 Swift 运行时必须同时更新并由 17-action 契约测试对齐。

## 2. System Volume Adapter

| Action | 参数 | 成功证据 | 失败/边界 |
| --- | --- | --- | --- |
| `system.volume.get` | `{}` | 返回当前输出设备和 0–100 音量 | 无默认输出设备则 failed |
| `system.volume.set` | `value`，0–100 | 执行后回读值在允许误差内 | 越界参数拒绝 |
| `system.volume.adjust` | `delta`，-100–100 | 执行后回读值在允许误差内 | 结果越界时截断并回读 |

- 优先 Core Audio 正式接口。
- 不切换输出设备，不控制麦克风，不绕过系统静音策略。
- 若目标设备不支持主音量，返回明确失败，不模拟成功。

## 3. Local Timer Adapter

| Action | 必填参数 | 成功证据 | 失败/边界 |
| --- | --- | --- | --- |
| `timer.create` | `timer_id`、`fire_at`、`label` | 持久化成功并可查询 | 过去时间、重复 ID 拒绝 |
| `timer.update` | `timer_id` + 至少一个变更字段 | 新状态持久化并替换通知 | 已触发/不存在拒绝 |
| `timer.cancel` | `timer_id` | 状态删除且通知取消 | 重复取消返回已有最终结果 |

- 使用 Bridge 自有存储和 UserNotifications，不写入 Reminders。
- 应用重启后恢复未到期计时器；已过期任务只触发一次，不补发多次。
- 标签进入用户通知，但不进入诊断日志。

## 4. EventKit Reminder Adapter

| Action | 必填参数 | 成功证据 | 失败/边界 |
| --- | --- | --- | --- |
| `reminder.create` | `reminder_id`、标题、到期时间 | EventKit 保存并回读稳定标识 | 权限未定先引导，拒绝后停止 |
| `reminder.update` | 稳定标识 + 变更字段 | 回读字段一致 | 目标不存在或已删除则 failed |
| `reminder.cancel` | 稳定标识 | EventKit 删除后不可查询 | 不按标题模糊删除 |

- 创建专用“小熙”提醒列表；首次使用时经用户确认创建。
- 不读取或同步无关提醒内容，不请求日历权限。
- 日志只记录本地映射 ID、动作和结果，不记录提醒正文。

## 5. Content Open Adapter

`content.open` 只接受以下一种目标，且不得同时提供：

- `bundle_id`：已注册 Bundle ID。
- `url`：`https` URL 且主机精确匹配或属于审核通过的子域规则。

执行前规范化 URL，拒绝 `file`、`javascript`、`data`、自定义脚本 Scheme、IP 字面量、用户名密码、重定向到非白名单和本地文件路径。应用未安装时不自动安装，返回 `app_not_installed`。

成功仅表示系统接受打开请求并找到目标应用；若业务页面是否正确无法回读，结果摘要必须说明证据级别。

## 6. Media Adapter

| Action | 参数 | 成功证据 |
| --- | --- | --- |
| `media.play` | 可选 `provider=system/netease_music` | 播放状态变为 playing，或返回 unknown |
| `media.pause` | 可选 `provider=system/netease_music` | 播放状态变为 paused，或返回 unknown |
| `media.previous` | 可选 `provider=system/netease_music` | 曲目标识变化或返回 unknown |
| `media.next` | 可选 `provider=system/netease_music` | 曲目标识变化或返回 unknown |

优先系统媒体接口或应用正式接口。仅触发媒体键但无法读取状态时不能返回 `succeeded`；应根据证据返回 `unknown`。

## 7. NetEase Music Adapter

### 7.1 目标

provider 为 `netease_music`。阶段一开始前安装网易云音乐并记录 Bundle ID、版本、macOS 版本、账号状态和接入方式。当前环境未安装网易云，文档不声明任何版本已经受支持。

### 7.2 动作

| Action | 参数 | 前置条件 | 成功证据 |
| --- | --- | --- | --- |
| `music.search_and_play` | `provider`、`query`；可选 artist/album | 已登录或允许的游客状态；版本受支持 | 搜索结果唯一或已消歧，实际曲目标题和播放状态回读 |
| `media.play/pause/previous/next` | `provider=netease_music` | 应用已安装且版本受支持 | 播放状态或曲目标识回读 |

### 7.3 接入与停止条件

1. 优先应用正式接口、URL Scheme 或稳定系统媒体接口。
2. 不满足搜索播放时才使用 AXUIElement。
3. AXUIElement 只按角色、标识、标题和层级关系定位，不使用绝对坐标。
4. 搜索结果不唯一时要求消歧；不默认点击第一项。
5. 关键元素缺失、窗口异常、登录弹窗、版本未知、网络失败或结果不可回读时停止。
6. 无法确认实际播放时返回 `unknown`，不得仅因点击成功返回 `succeeded`。

### 7.4 支持版本记录

| 应用版本 | macOS | 接入方式 | 搜索播放 | 状态回读 | 结论 |
| --- | --- | --- | --- | --- | --- |
| 待安装后填写 | 待填写 | 待研判 | 未验证 | 未验证 | 不支持声明 |

## 8. WeChat Adapter

### 8.1 目标与数据边界

provider 为 `wechat`。阶段一只允许微信测试账号和测试联系人。当前本机 `com.tencent.xinWeChat` 版本 `4.1.12` 是研判基线，不代表支持结论。

不读取全量通讯录，不把联系人或消息正文写入日志、动作历史、能力快照或诊断包。

### 8.2 草稿

`chat.draft` 参数：provider、联系人精确名称或稳定标识、完整正文。

执行规则：

1. 校验微信已安装、已登录、版本受支持且关键窗口状态明确。
2. 按稳定语义搜索联系人；0 个或多个匹配均返回 `target_ambiguous` 或明确缺失。
3. 打开唯一会话并填入正文，不触发发送。
4. 回读当前会话和输入框摘要，生成草稿摘要供设备复述。
5. 任何 Enter、发送按钮或可能产生外部影响的动作在草稿阶段禁止。

### 8.3 发送

`chat.send` 参数：`provider=wechat`、`user_id`、`device_id`、`session_id`、联系人 `target_id` 和 `draft_sha256`；confirmation 位于 Command 顶层，不重复放入 parameters。

执行规则：

1. 重新校验应用、版本、会话、联系人和输入框内容。
2. 验证确认凭据签名、设备/Bridge 绑定、联系人、草稿 SHA-256、有效期和未使用状态。
3. 只执行一次发送动作，并立即标记确认已使用。
4. 通过会话 UI 的新增消息状态验证结果；无法验证时返回 `unknown`。
5. 超时、断线、应用卡死、弹窗、会话切换或结果未知时禁止自动重试。

### 8.4 接入和停用

- 优先正式接口；缺失时使用 AXUIElement，不使用坐标点击或全局键盘脚本。
- 关键元素、层级或行为变化即视为版本不兼容，远程/本地停用适配器。
- 每个支持版本必须通过草稿无发送、歧义停止、确认失效、重放不重复发送和未确认发送为 0。

### 8.5 支持版本记录

| 应用版本 | macOS | 接入方式 | 草稿 | 确认发送 | 结论 |
| --- | --- | --- | --- | --- | --- |
| 4.1.12 | 当前研判环境 | 未冻结 | 未验证 | 未验证 | 不支持声明 |

## 9. 权限矩阵

| 适配器 | 本地网络 | 通知 | 提醒事项 | 辅助功能 | 自动化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| LAN Transport | 必需 | 否 | 否 | 否 | 否 |
| System Volume | 否 | 否 | 否 | 否 | 视正式接口而定 |
| Local Timer | 否 | 必需 | 否 | 否 | 否 |
| EventKit Reminder | 否 | 可选 | 必需 | 否 | 否 |
| Content Open | 否 | 否 | 否 | 否 | 否 |
| Media/NetEase | 否 | 否 | 否 | 仅兜底 | 视接入方式而定 |
| WeChat | 否 | 否 | 否 | 仅兜底 | 视接入方式而定 |

权限按能力申请。拒绝某一权限只停用对应能力，不影响菜单栏、诊断和其他适配器。

## 10. 适配器完成定义

- 支持版本、接入方式、前置条件和停止条件已记录。
- 参数、风险、权限、超时和错误映射与 `08_bridge_protocol.md` 一致。
- 正常、拒绝、失败、超时、重复和结果未知均有自动或实机证据。
- 单个适配器可停用，其他能力无回归。
- 日志和诊断通过敏感字段检查。
- 对应 `04_acceptance_checklist.md` 项全部通过后，才能标记该适配器已完成。
