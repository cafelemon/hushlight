# 小熙 Hushlight H0C Rev A 在线工程接线清单入口

> 版本：V1.0
> 更新日期：2026-08-20
> 状态：在线工程逐页并行施工基线
> 权威电气边界：[10_hardware_board_design_spec.md](10_hardware_board_design_spec.md)

## 结论

接线清单已从单文档全工程累计编号改为“每个在线原理图页一份清单、每页从 1 连续编号”。旧版 01 页 1–212 清单原样保留为阶段证据，不再作为当前施工入口。

当前入口：[wiring/README.md](wiring/README.md)。

## 当前状态

| 图页 | 连续编号 | 状态 |
|---|---:|---|
| `01POWERUSB` | 1–208 | 人工接线与人工复核完成；ERC 0 致命/0 错误/30 警告 |
| `02-MCU-DEBUG` | 1–42 | 可独立施工 |
| `03-AUDIO-IN` | 从 1 开始 | 供电/数字域开放；模拟前端受 `H-MIC-001` Gate |
| `04-AUDIO-OUT` | 从 1 开始 | 供电/数字域开放；Codec→PA 增益受音频 Gate |
| `05-HEAD-LINK` | 从 1 开始 | 30Pin 网络契约已定义；实物方向受 `H-FFC-001` Gate |
| `06-MOTION-IO` | 1–33 | 可独立施工；电机/编码器/限位受 Gate |
| `07-CONNECTORS-TEST` | 从 1 开始 | 候选连接器与静音件只清点，不冻结线束 |
| Head 4 页 | 各从 1 开始 | 2026-08-21 已清除旧 `03-FLEX-TEST` 候选，当前均仅 A4 图框；按各自 Gate 分工推进 |

## 阶段留存

- [旧版阶段性 1–212 接线交接单](archive/11_h0c_reva_schematic_wiring_handoff_stage_2026-08-20.md)
- [2026-08-20 ERC 复核记录](../hardware/h0/evidence/H0C_RevA_ERC_review_2026-08-20_160900.md)

## 变更规则

1. 施工人员只更新自己负责页面的清单状态，不修改其他页面编号。
2. 新增器件先放对应页图框外，记录型号/封装/来源；通过复核后再移入和接线。
3. `GATE` 不得通过猜接、接地或全局 ERC 忽略关闭。
4. 任何跨页网络更名必须同时更新主索引、源页、消费页和 ERC 证据。
