# H0C Rev A 在线工程逐页接线清单

> 版本：V1.0  
> 基线日期：2026-08-20  
> 适用工程：嘉立创 EDA 在线工程 `hushlight`  
> 使用方式：每个原理图页独立分工、独立编号、独立复核；编号均从 1 开始。

## 1. 当前基线

- 旧版 01 页 1–212 阶段清单已原样归档；其中撤销项 44/45、重复更正项 209–212 不进入新清单。
- `01POWERUSB` 新清单压实为连续 1–208，状态为“人工接线与人工复核完成，ERC 0 致命/0 错误/30 警告”。
- 在线工程页面树以 2026-08-20 实际读取为准：Base 8 页，Head 4 页。
- 清单只发布 `A`（可执行）连接；`GATE` 行是停止条件，不得为了消除 ERC 自行接线。
- 跨页使用网络标签，不画跨页长线。每条接线完成后填写执行人、日期和复核人。

## 2. 分工索引

| 板卡 | 在线图页 | 清单 | 当前状态 | 可并行工作 |
|---|---|---|---|---|
| Base | `00_SYSTEM` | [00_base_system.md](00_base_system.md) | 框图/跨页契约 | 维护电源树和 Gate，不画器件线 |
| Base | `01POWERUSB` | [01_power_usb.md](01_power_usb.md) | 接线完成，ERC 待逐项解释 | 只做复核与警告分类 |
| Base | `02-MCU-DEBUG` | [02_mcu_debug.md](02_mcu_debug.md) | A 表开放 | 可独立施工 |
| Base | `03-AUDIO-IN` | [03_audio_in.md](03_audio_in.md) | 数字/供电 A 表开放；模拟链 Gate | 可完成供电、数字总线和已冻结耦合件布局 |
| Base | `04-AUDIO-OUT` | [04_audio_out.md](04_audio_out.md) | 数字/供电 A 表开放；模拟增益 Gate | 可完成供电、数字总线和参考电容布局 |
| Base | `05-HEAD-LINK` | [05_head_link.md](05_head_link.md) | FFC 针序已定义，实物方向 Gate | 只做基于 30Pin 契约的页内准备 |
| Base | `06-MOTION-IO` | [06_motion_io.md](06_motion_io.md) | A 表开放；电机/传感器 Gate | 可独立施工 1–33 |
| Base | `07-CONNECTORS-TEST` | [07_connectors_test.md](07_connectors_test.md) | 候选器件 Gate | 只做清点与机械证据收集 |
| Head | `00-SYSTEM` | [head_00_system.md](head_00_system.md) | 空页/Gate | 冻结 Head 供电与跨页契约 |
| Head | `01-DISPLAY-TOUCH` | [head_01_display_touch.md](head_01_display_touch.md) | 空页/Gate | 等模组 34Pin 与实物通断表 |
| Head | `02-CAMERA-PRIVACY` | [head_02_camera_privacy.md](head_02_camera_privacy.md) | 空页/Gate | 等摄像头/隐私件实物 Gate |
| Head | `03-FLEX-TEST` | [head_03_flex_test.md](head_03_flex_test.md) | 空页/Gate | 等 FFC 同异面与 Pin 1 证据 |

## 3. 共用执行规则

1. 每行只完成一根导线或一个网络标签；同一端点多次出现代表明确分叉。
2. 每页编号独立从 1 连续累计，不使用旧 `Axx`、全工程累计号或撤销号。
3. `NC` 必须放非连接标识；`DNP` 必须关闭 BOM/PCB 或按清单说明留兼容焊盘；`GATE` 不得伪装为 NC。
4. 新增器件先放在对应页面图框外空白处，完成型号、封装、供应商编号和数据手册核对后，才允许移入功能块。
5. 禁止移动或重画其他人员已完成的复杂线区；发现疑点先记录端点、网名和截图，由原执行人复核。
6. 页内完成后执行：编号连续性检查 → 端点成员检查 → NC/DNP 检查 → ERC → 截图复核 → 更新状态。

## 4. 跨页网络所有权

| 网络 | 产生/驱动页 | 消费页 | 验收规则 |
|---|---|---|---|
| `5V_SYS` | 01 | 01、04 | 只能在 L1 后产生；任何跨页成员不得回到 `VBUS_PD` |
| `BASE_3V3` | 01 | 01–07 | U7 输出；I²C 与开漏上拉只能使用此轨 |
| `AUDIO_3V3A` | 01 | 03、04 | 只供音频模拟域；不得与 Motor 回流串接 |
| `MIC_2V8` | 03 | 03 | U16 输出，经物理静音链后才到两颗麦克风 |
| `SYS_I2C_SCL/SDA` | 02 唯一上拉 | 01、02、03、04 | 只允许 R6/R7 一对上拉 |
| `I2S_MCLK/BCLK/LRCK` | 02/U1 | 03、04 | U1 输出，共享时钟；源端串阻位由后续 SI Gate 冻结 |
| `ADC_SDOUT` | 03/U4 | 02/U1 | ES7210 输出到 Base 输入 |
| `DAC_DSDIN` | 02/U1 | 04/U3 | Base 输出到 ES8311 输入 |
| `HEAD_5V` | 01/U11 | 05、Head 00 | 由 Head eFuse 产生；FFC 5–8 并联 |
| `MOTOR_5V` | 01/U12 | 06 | 只供 DRV8833 与 Motor bulk |
| `MOTION_UART_TX/RX` | 02 ↔ 06 | 06 ↔ 02 | 必须 TX→RX 交叉，不按同名方向直连 |

## 5. 阶段留存

- 旧阶段清单：[11_h0c_reva_schematic_wiring_handoff_stage_2026-08-20.md](../archive/11_h0c_reva_schematic_wiring_handoff_stage_2026-08-20.md)
- 当前主入口：[11_h0c_reva_schematic_wiring_handoff.md](../11_h0c_reva_schematic_wiring_handoff.md)
- 正式电气/GPIO/接口权威：[10_hardware_board_design_spec.md](../10_hardware_board_design_spec.md)
