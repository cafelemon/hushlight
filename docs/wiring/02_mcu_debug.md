# Base `02-MCU-DEBUG` 接线清单

> 状态：A 表开放。执行前把 `R45` 移入 U13.INT 附近；J5、TP1–TP6、未分配 GPIO 暂不接。

| 编号 | 源引脚 | 目标网络/引脚 | 说明 | 执行/复核 |
|---:|---|---|---|---|
| 1 | `U1-3V3` | `BASE_3V3` | Base-S3 主电源 | |
| 2 | `C10-1` | `BASE_3V3` | 22µF bulk | |
| 3 | `C10-2` | `GND` | bulk 回流 | |
| 4 | `C9-1` | `BASE_3V3` | 10µF 去耦 | |
| 5 | `C9-2` | `GND` | 去耦回流 | |
| 6 | `C11-1` | `BASE_3V3` | 100nF 高频去耦 | |
| 7 | `C11-2` | `GND` | 高频回流 | |
| 8 | `U1-GND（左）` | `GND` | 模组地 | |
| 9 | `U1-GND（右上）` | `GND` | 模组地 | |
| 10 | `U1-EN` | `R8-1` | EN 上拉节点 | |
| 11 | `U1-EN` | `C12-1` | EN RC | |
| 12 | `U1-EN` | `SW1-1` | RESET 按键 | |
| 13 | `R8-2` | `BASE_3V3` | 10kΩ | |
| 14 | `C12-2` | `GND` | 1µF | |
| 15 | `SW1-2` | `GND` | 按下复位 | |
| 16 | `U1-IO0` | `R9-1` | BOOT 上拉节点 | |
| 17 | `U1-IO0` | `SW2-1` | BOOT 按键 | |
| 18 | `R9-2` | `BASE_3V3` | 10kΩ | |
| 19 | `SW2-2` | `GND` | 按下进入下载条件 | |
| 20 | `U13-VCC` | `BASE_3V3` | TCA9554 电源 | |
| 21 | `C13-1` | `BASE_3V3` | 100nF | |
| 22 | `U13-GND` | `GND` | TCA9554 地 | |
| 23 | `C13-2` | `GND` | 去耦回流 | |
| 24 | `U13-A0` | `GND` | 地址位 0 | |
| 25 | `U13-A1` | `GND` | 地址位 0 | |
| 26 | `U13-A2` | `GND` | 地址位 0；7-bit `0x20` | |
| 27 | `U13-SCL` | `SYS_I2C_SCL` | I²C 时钟 | |
| 28 | `U1-IO18` | `SYS_I2C_SCL` | Base 端时钟 | |
| 29 | `R6-1` | `SYS_I2C_SCL` | 唯一 SCL 上拉 | |
| 30 | `R6-2` | `BASE_3V3` | 4.7kΩ | |
| 31 | `U13-SDA` | `SYS_I2C_SDA` | I²C 数据 | |
| 32 | `U1-IO17` | `SYS_I2C_SDA` | Base 端数据 | |
| 33 | `R7-1` | `SYS_I2C_SDA` | 唯一 SDA 上拉 | |
| 34 | `R7-2` | `BASE_3V3` | 4.7kΩ | |
| 35 | `U13-INT` | `IOEXP_IRQ_N` | 开漏低有效 | |
| 36 | `U1-IO40` | `IOEXP_IRQ_N` | Base 输入 | |
| 37 | `R45-1` | `IOEXP_IRQ_N` | 唯一 INT 上拉 | |
| 38 | `R45-2` | `BASE_3V3` | 10kΩ | |
| 39 | `U13-P4` | `HEAD_OC_N` | 读取 U11 FLT# | |
| 40 | `U13-P5` | `MOTOR_OC_N` | 读取 U12 FLT# | |
| 41 | `U1-GPIO16` | `HEAD_PWR_EN` | Head eFuse 主动高使能 | |
| 42 | `U1-GPIO47` | `MOTION_KILL_N` | Motor 授权/硬 kill | |

Gate：U1 USB/UART 服务口保护、J5 最终针序、TCA9554 P0–P3 业务连接和未分配 GPIO，不进入本批。
