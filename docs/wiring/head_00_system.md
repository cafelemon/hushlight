# Head `00-SYSTEM` 任务清单

> 当前页为空白 A4 图框。编号从 1 开始；`H-IO-001` 未关闭前只维护跨页契约，不放未知模组符号。

| 编号 | 任务 | 状态 | 关闭证据 |
|---:|---|---|---|
| 1 | 冻结 Head 计算/显示模组完整采购型号和硬件版本 | GATE | 实物照片、订单型号、官方原理图版本 |
| 2 | 冻结官方 34Pin 扩展口逐针表 | GATE | 实物通断 + 官方图双证据 |
| 3 | 定义 `HEAD_5V/GND` 入口与防回灌边界 | GATE | 模组供电范围、浪涌、断电 IO 实测 |
| 4 | 定义 Base FFC 到 Head 的 30Pin 跨页端口 | A-CONTRACT | 与 Base 05 表逐针一致 |
| 5 | 定义 Head SPI/UART/IRQ/READY/RESET/BOOT 页间网络 | GATE | `H-IO-001` 可用 GPIO 表 |
| 6 | 定义 Camera/Privacy 与 Display/Touch 的供电时序 | GATE | 模组/摄像头数据手册与实测 |

首批缺件候选 `J_HEAD_MODULE` 不落图：连接器/插座型号取决于实际 AMOLED 模组 34Pin 机械结构，必须先取得实物。
