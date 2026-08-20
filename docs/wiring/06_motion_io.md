# Base `06-MOTION-IO` 接线清单

> 状态：1–33 开放；GPIO2、两路 H 桥输出、电机座、编码器和限位仍为 Gate。

| 编号 | 源引脚 | 目标网络/引脚 | 说明 | 执行/复核 |
|---:|---|---|---|---|
| 1 | `U9-VM（10）` | `MOTOR_5V` | DRV8833 电源 | |
| 2 | `C27-1` | `MOTOR_5V` | 10µF | |
| 3 | `C26-1` | `MOTOR_5V` | 100nF | |
| 4 | `C29-正` | `MOTOR_5V` | 470µF bulk | |
| 5 | `U9-GND（11）` | `GND` | 不得误接 pin 13 | |
| 6 | `U9-PowerPAD` | `GND` | 裸露焊盘 | |
| 7 | `C27-2` | `GND` | 回流 | |
| 8 | `C26-2` | `GND` | 回流 | |
| 9 | `C29-负` | `GND` | 极性回流 | |
| 10 | `U9-VCP（9）` | `C28-1` | 点到点 | |
| 11 | `C28-2` | `MOTOR_5V` | 10nF 跨 VCP–VM | |
| 12 | `U9-VINT（12）` | `C25-1` | 点到点 | |
| 13 | `C25-2` | `GND` | 2.2µF | |
| 14 | `U9-AISEN（1）` | `GND` | Rev A 不做电流调节 | |
| 15 | `U9-BISEN（4）` | `GND` | Rev A 不做电流调节 | |
| 16 | `U9-nSLEEP（15）` | `DRV_nSLEEP` | 驱动使能 | |
| 17 | `U8-GPIO21` | `DRV_nSLEEP` | C3 控制 | |
| 18 | `R12-1` | `DRV_nSLEEP` | 10kΩ 默认下拉上端 | |
| 19 | `R12-2` | `GND` | 复位时睡眠 | |
| 20 | `U9-nFAULT（6）` | `DRV_FAULT_N` | 开漏低有效 | |
| 21 | `U8-GPIO10` | `DRV_FAULT_N` | 只作输入 | |
| 22 | `R13-1` | `DRV_FAULT_N` | 10kΩ 上拉信号端 | |
| 23 | `R13-2` | `BASE_3V3` | 上拉电源 | |
| 24 | `U8-GPIO0` | `PAN_IN1` | 非绑带 PWM | |
| 25 | `U9-AIN1（14）` | `PAN_IN1` | 同网 | |
| 26 | `U8-GPIO1` | `PAN_IN2` | 非绑带 PWM | |
| 27 | `U9-AIN2（13）` | `PAN_IN2` | pin 13 不是 GND | |
| 28 | `U8-GPIO3` | `TILT_IN2` | GPIO2/BIN1 保持 Gate | |
| 29 | `U9-BIN2（8）` | `TILT_IN2` | 同网 | |
| 30 | `U1-GPIO21` | `MOTION_UART_TX` | Base TX | |
| 31 | `U8-GPIO18` | `MOTION_UART_TX` | Motion RX | |
| 32 | `U8-GPIO19` | `MOTION_UART_RX` | Motion TX | |
| 33 | `U1-GPIO38` | `MOTION_UART_RX` | Base RX | |

Gate：`U8.GPIO2→U9.BIN1`、AOUT/BOUT、编码器、限位、电机座及保护网络，等待 `H-MOT-001/H-ENC-001`。
