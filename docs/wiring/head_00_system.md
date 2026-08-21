# Head `00-SYSTEM` 任务清单

> 2026-08-21 已以精确料号放置 `U18=ESP32-S3-WROOM-1-N16R8/C2913202`，但尚未接线、未放显示/相机/FFC 座，未运行页级 Gate。编号从 1 开始；`H-IO-001` 未关闭前不放未知 IPS、触控或相机符号。

| 编号 | 任务 | 状态 | 关闭证据 |
|---:|---|---|---|
| 1 | Head-S3 已选 `ESP32-S3-WROOM-1-N16R8/C2913202`；冻结 IPS、触控的完整采购型号和硬件版本 | GATE | Head-S3 实体已落图；IPS/触控仍需实物照片、订单型号、各自 datasheet/RFQ 版本 |
| 2 | 冻结 Head-S3、IPS/触控与摄像头的跨页 Pin Budget | GATE | P-01/P-04 datasheet + 实物通断 + 原理图三方一致 |
| 3 | 定义 `HEAD_5V/GND` 入口与防回灌边界 | GATE | Head-S3、IPS、触控供电范围、浪涌、断电 IO 实测 |
| 4 | 定义 Base FFC 到 Head 的 30Pin 跨页端口 | A-CONTRACT | 与 Base 05 表逐针一致 |
| 5 | 定义 Head SPI/UART/IRQ/READY/RESET/BOOT 页间网络 | GATE | `H-IO-001` 可用 GPIO 表 |
| 6 | 定义 Camera/Privacy 与 Display/Touch 的供电时序 | GATE | IPS/触控/摄像头 datasheet 与实测 |

## 已预放置、禁止接线的器件

下表是 2026-08-21 在嘉立创EDA `00-SYSTEM` 页的实物库件。所有器件均为 `未连线`：不能据此导出可下单 BOM、不能把电容/电阻默认归入任何网络，也不关闭 `H-PWR-001/H-IO-001`。

| 位号 | 实际料号 / 嘉立创料号 | 预期角色（未连接） | 状态 |
|---|---|---|---|
| `U18` | `ESP32-S3-WROOM-1-N16R8` / `C2913202` | Head-S3 主控 | `PREPLACED-NOWIRE` |
| `U19` | `TPS62132RGTR` / `C81563` | 5V→3.3V Buck 首板候选 | `PREPLACED-NOWIRE` |
| `C69` | 10µF 0805 X5R / `C440198` | Head 3.3V 候选 bulk | `PREPLACED-NOWIRE` |
| `C70` | 100nF 0402 X7R / `C1525` | Head-S3 高频去耦候选 | `PREPLACED-NOWIRE` |
| `C71` | 1µF 0402 X7R / `C52923` | EN RC 或电源候选去耦 | `PREPLACED-NOWIRE` |
| `R30` | 10kΩ 0402 / `C25744` | EN 上拉候选 | `PREPLACED-NOWIRE` |
| `R31` | 10kΩ 0402 / `C25744` | IO0/BOOT 上拉候选 | `PREPLACED-NOWIRE` |

首批缺件候选 `J_LCD/J_TP` 不落图：FPC 座与保护取决于实际 IPS/触控的 FPC、Pin 1 和机械结构，必须先取得实物。
