# Base `05-HEAD-LINK` 接线清单

> 30Pin 网络契约已批准，但 `FPC1=FH12-30S-0.5SH(55)` 的同/异面、Pin 1 和线束方向仍需 `H-FFC-001` 实物 Gate。以下编号从 1 开始，状态均为 `GATE-HOLD`，不得提前接 FPC1。

| 编号 | FFC Pin | 网络 | 方向（Base 视角） | 状态/规则 |
|---:|---:|---|---|---|
| 1 | 1 | `GND` | — | GATE-HOLD |
| 2 | 2 | `GND` | — | GATE-HOLD |
| 3 | 3 | `GND` | — | GATE-HOLD |
| 4 | 4 | `GND` | — | GATE-HOLD |
| 5 | 5 | `HEAD_5V` | 输出 | 四针并联，核对单针额定电流 |
| 6 | 6 | `HEAD_5V` | 输出 | 同上 |
| 7 | 7 | `HEAD_5V` | 输出 | 同上 |
| 8 | 8 | `HEAD_5V` | 输出 | 同上 |
| 9 | 9 | `HEAD_SPI_SCLK` | 输出 | Base 源端 22Ω 串阻 |
| 10 | 10 | `GND` | — | SPI 时钟回流 |
| 11 | 11 | `HEAD_SPI_MOSI` | 输出 | Base 源端 22Ω 串阻 |
| 12 | 12 | `HEAD_SPI_MISO` | 输入 | Head 源端串阻 |
| 13 | 13 | `HEAD_SPI_CS_N` | 输出 | Base 源端串阻；默认上拉 Gate |
| 14 | 14 | `GND` | — | 数据信号回流 |
| 15 | 15 | `HEAD_IRQ_N` | 输入 | 开漏优先；上拉 Gate |
| 16 | 16 | `HEAD_READY` | 输入 | 下拉防悬空；值 Gate |
| 17 | 17 | `HEAD_RESET_N` | 输出 | 默认上拉 Gate |
| 18 | 18 | `HEAD_PWR_EN` | 输出 | 只控制 Base eFuse，不跨 FFC 驱动负载 |
| 19 | 19 | `HEAD_UART_TX` | 输出 | 115200 恢复通道 |
| 20 | 20 | `HEAD_UART_RX` | 输入 | 115200 恢复通道 |
| 21 | 21 | `CAM_ACTIVE_LED_SENSE` | 输入 | 隐私工作灯回读 |
| 22 | 22 | `SHUTTER_CLOSED_N` | 输入 | 物理遮挡检测，安全默认 |
| 23 | 23 | `HEAD_TEMP_ALERT_N` | 输入 | Rev A DNP 兼容位 |
| 24 | 24 | `HEAD_BOOT_N` | 输出 | 仅服务模式；默认上拉 Gate |
| 25 | 25 | `SPARE_DIFF_P` | 保留 | Rev A DNP |
| 26 | 26 | `SPARE_DIFF_N` | 保留 | Rev A DNP |
| 27 | 27 | `SPARE_GPIO0` | 保留 | 串阻/DNP |
| 28 | 28 | `SPARE_GPIO1` | 保留 | 串阻/DNP |
| 29 | 29 | `GND` | — | 尾部回流 |
| 30 | 30 | `GND` | — | 尾部回流/屏蔽 |

框外缺件保持 Gate：FFC ESD 阵列、`HEAD_SPI_CS_N/HEAD_RESET_N` 上拉和 `HEAD_READY` 下拉。只有实物 30Pin 线束同异面、Pin 1 照片及两端通断表齐全后，才能选择型号和接线。
