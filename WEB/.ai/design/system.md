# Hushlight 小熙 Design System

> Surface: responsive web console  
> Status: W0 Baseline  
> Updated: 2026-08-13  

## Audience And Tasks

- Primary users: 20–35 岁成年用户；希望快速理解设备与电脑能力状态，不具备技术背景。
- Repeated tasks: 查看连接、调整陪伴模式、管理主动关怀、复核权限、查看或删除记忆、追踪动作结果。
- High-risk actions: 记忆删除、能力停用、外部消息发送；W0 不实现真实外部动作。

## Foundations

- Density: 中等偏疏；总览可扫描，设置页单任务聚焦。
- Navigation: 桌面 248px 左侧栏；小于 760px 使用顶部品牌栏与横向滚动导航。
- Grid and responsive breakpoints: 内容最大 1180px；960px 双列转单列；760px 切换移动导航；390px 为最小验收宽度。
- Typography: 系统无衬线字体；标题 28/34，页面标题 26/32，正文 14–16/1.6；数字使用 tabular nums。
- Logo asset and language variant: W0 使用文字标识 `Hushlight / 小熙` 与自绘光点图形；正式 Logo 待品牌资产确认。
- Logo surface and minimum display size: 暖白或深墨色平面，文字标识最小宽度 112px。
- Brand colors: Ink `#232220`，Warm white `#fbfaf7`，Apricot `#ef9b69`，Amber `#e8b558`，Sage `#6d8b7b`。
- Semantic colors: success `#34745b`，warning `#a96819`，danger `#a84943`，info `#456a8f`；状态同时使用文字与图标。
- Icon library: Lucide，线宽统一 1.8；所有图标按钮必须有可访问名称。

## Components And States

| Component | Purpose | Variants | Required states | Responsive behavior |
| --- | --- | --- | --- | --- |
| App shell | 全局导航与数据来源提示 | desktop/mobile | active/focus | 移动端顶部堆叠 |
| Status pill | 表达连接或结果 | success/warning/danger/neutral | icon + text | 不缩成纯色点 |
| Summary metric | 总览关键状态 | normal/actionable | loading/empty/error | 三列转单列 |
| Setting row | 设置与权限 | switch/link/status | enabled/disabled/pending | 操作保持 44px 触控区 |
| Activity item | 结果追踪 | success/failure/blocked/pending | empty/long text | 时间与状态换行 |
| Empty state | 解释缺失与下一步 | calm/actionable | no data/offline/no permission | 文案居中，按钮全宽可选 |

## Accessibility

- Keyboard and focus: `:focus-visible` 使用 3px 暖橙外环；导航与开关遵循 DOM 顺序。
- Labels and semantics: 页面一个 H1；状态使用可读文字；开关使用原生 button + `aria-pressed`。
- Contrast and non-color cues: 状态包含图标和文本；正文目标 WCAG AA。
- Text resize and zoom: 不禁用缩放；200% 缩放不遮挡主要任务。
- Touch targets: 移动端交互区最小 44×44px。

## Approved Decisions

| Date | Decision | Reason | Scope |
| --- | --- | --- | --- |
| 2026-08-13 | 温暖中性色 + 克制杏橙作为主强调 | 传达陪伴感，同时保持配置控制台的可信与清晰 | W0 全站 |
| 2026-08-13 | 不使用拟人照片、渐变光球或营销 Hero | Web 是低频管理面，不应抢占设备的角色表达 | W0 全站 |
| 2026-08-13 | 所有 W0 数据持续标注“本地预览” | 不把界面骨架误当成真实接入证据 | W0 全站 |

## Rejected Patterns

| Pattern | Reason | Alternative |
| --- | --- | --- |
| 大面积渐变与漂浮光球 | 装饰压过状态与操作 | 暖白平面、轻纹理与单色强调 |
| 多层圆角卡片嵌套 | 降低扫描效率 | 无框分区 + 单层列表 |
| 只用绿/红色表达状态 | 色觉与语义风险 | 图标 + 状态文字 + 颜色 |
| 技术术语直接面向用户 | 增加安装与授权负担 | 使用能力和用户结果语言 |
