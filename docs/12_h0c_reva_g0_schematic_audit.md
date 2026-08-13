# 小熙 Hushlight H0C Rev A G0 原理图审计与接线收敛单

> 日期：2026-08-13  
> 状态：审计完成；存在 2 项 P0，未关闭前禁止开始 `01POWERUSB` 的 CC 与 `SYS_I2C` 接线  
> 范围：只读核对嘉立创 EDA、`10_hardware_board_design_spec.md`、`11_h0c_reva_schematic_wiring_handoff.md` 与关键器件原厂 datasheet；未移动元件、未连线、未保存 EDA

## 1. 结论

当前工程可继续整理和核对，但**不能按原接线单直接开接**。`D4` 的电压等级不适配 Type-C CC，且 `SYS_I2C` 的上拉设计出现两组候选并联。两项都在实际画线前暴露，尚未造成 PCB 或物料损失。

## 2. 审计证据与当前状态

| 项 | 结果 |
|---|---|
| EDA 基础工程 | `H0-BASE-REVA` 与 `H0-HEAD-REVA` 均存在；Base 页 01/02/04 可见，Head 页仍为 Gate 占位 |
| `01POWERUSB` | 70 件已落图，按 USB/PD、Buck、LDO、eFuse 分区；尚无可验收的完整电源网络 |
| `02-MCU-DEBUG` | 21 件已落图，`R45=10kΩ` 存在且未接线 |
| `04-AUDIO-OUT` | 存在若干未命名绿线片段；不能据此认定功放 bulk 或 Codec 网络已正确连接 |
| Head Carrier | 空白/Gate 状态符合当前 `H-IO-001` 约束；没有把未知显示或摄像头 GPIO 伪接入 |

## 3. 审计问题

| ID | 级别 | 发现 | 依据 | 必须动作 |
|---|---|---|---|---|
| `P0-01` | P0 | `D4=TPD2E2U06DRLR` 被规划为 CC ESD，但该器件 `VRWM=5.5V`、`VBR≥6.5V`；STUSB4500 的 CC 可能面临最高 22V short-to-VBUS | [TPD2E2U06 datasheet](https://www.ti.com/lit/ds/symlink/tpd2e2u06.pdf)、[STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf) | 保留 D4 落图记录但不接线、不计入 CC BOM；改为 CC 专用 short-to-VBUS 保护方案后再接。`TPD2S300` 可作为 24V CC 专用保护候选，须单独核对供电、死电池模式、封装和嘉立创可得性 |
| `P0-02` | P0 | `01.R30/R31` 与 `02.R_I2C_SCL/SDA` 都是 `SYS_I2C` 的 4.7kΩ 上拉候选；若全装并接，每线等效 2.35kΩ | `11` 第 3.1、3.6、4.1 节与 GPIO/I²C 表 | 只保留一对；建议保留 02 页逻辑对、将 R30/R31 标 DNP/改位。未批准前，不连接 STUSB4500、TCA9554 或 Codec 的 `SYS_I2C` |
| `P1-01` | P1 | `04-AUDIO-OUT` 已有未命名导线片段，连接范围未能由网名或器件引脚证明 | EDA 只读画布 | 逐段复核。只有明确的 `5V_SYS`、`AUDIO_3V3A`、`GND` 或获批信号网可以保留；不明片段不得参与后续连接 |
| `P1-02` | P1 | DRV8833 的 `VCP`、`VINT`、`AISEN/BISEN`、PowerPAD 未在原清单逐脚列出，易在手工接线中遗漏 | [DRV8833 datasheet](https://www.ti.com/lit/ds/symlink/drv8833.pdf) | 按 11 第 4.5.1 节补齐；先以现有 C25…C29/R12/R13 的值核对功能位，不能按自动位号猜接 |
| `P1-03` | P1 | 两颗 TPS259470 的 `AUXOFF` 未进入功能连线表 | [TPS25947 datasheet](https://www.ti.com/lit/ds/symlink/tps25947.pdf) | Rev A 不做电源 MUX 时显式标 `NC`；不得误接成 `FLT` 或 `PG`。`FLT` 仅 pin 4，`AUXOFF` 为 pin 3 |
| `GATE-01` | 保持 Gate | 模拟麦、Codec 模拟外围、静音硬断开、FFC 方向、Head GPIO、相机、电机/编码器/限位接口仍未冻结 | `10` Gate 表、`11` 待补放表 | 不为消除 ERC 或“先跑起来”而接线 |

## 4. 接线执行顺序（审计后版本）

1. 先关闭 `P0-01` 和 `P0-02`，并同步更新 10/11 与 EDA 物料状态。
2. `01POWERUSB`：按 11 第 3.1–3.5 节，先 VBUS/TVS/P-MOS，再 TPS56637，再 TPS62132/LDO，最后两颗 eFuse；每完成一个局部网立即检查其成员。
3. `02-MCU-DEBUG`：接 Base 电源/EN/BOOT/TCA9554/R45；`SYS_I2C` 只在唯一上拉对确认后接入。
4. `06-MOTION-IO`：先完成 DRV8833 的 VM、VCP、VINT、ISEN、nSLEEP、nFAULT，再接已批准的 UART/PWM；不接 GPIO2、限位或编码器 Gate 线。
5. `03/04-AUDIO`：只接已验证的数字电源/本地去耦与明确数字 I²S；模拟麦、AEC、Codec→功放模拟链在音频 pin mapping Gate 后接。
6. `05/07/Head`：按 FFC/线束/静音/Head Gate 逐项开放；不可通过“预接长线”绕过 Gate。
7. 各页完成后运行未连接引脚检查；所有页收敛后才运行 ERC。ERC 通过不等于 G1/G2/采购通过。

## 5. 接线前后检查卡

| 检查点 | 接线前 | 接线后 |
|---|---|---|
| CC | CC 专用 24V short-to-VBUS 保护已确认；D4 未接 | CC1/CC2 只通过获批保护通道到 U5；无 5.1kΩ Rd |
| I²C | 唯一 4.7kΩ 上拉对已选定 | 每线只有一只等效上拉；地址表 `0x18/0x20/0x28/0x40` 无冲突 |
| eFuse | ILM、OVLO、EN/UVLO、DVDT、ITIMER、FLT/AUXOFF 角色已核对 | ILM 无 ADC/长线分支；AUXOFF 显式 NC；FLT 各自一只上拉 |
| DRV8833 | C25…C29/R12/R13 已按功能而非位号核对 | VM/VCP/VINT/ISEN/PowerPAD 完整；nSLEEP 默认低；nFAULT 开漏上拉 |
| 音频 | 04 的已有线段均有命名和端点证明 | PA bulk 只跨 5V_SYS/GND；BTL 输出无任一端接地 |
| Gate | 未冻结项均标记 | ERC 中只豁免有 ID 的 Gate/NC 项 |

## 6. 不在本轮处理的事项

- 替代 CC 保护器件的最终 LCSC 编号、库存、贴装可用性和价格。
- Head 模组、摄像头、模拟麦、编码器、限位、静音开关和线束的最终型号/针序。
- PCB、BOM、Gerber、采购和下单。
