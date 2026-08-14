# 小熙 Hushlight H0C Rev A G0 原理图审计与接线收敛单

> 日期：2026-08-13  
> 状态：两项 P0 已关闭；2026-08-13 已在嘉立创 EDA 删除 `D4/R30/R31` 并保存。仍不代表 ERC、PCB、BOM、打板或采购放行
> 范围：审计、器件核对、EDA 定向修复与文档收敛；未新增任何导线、未运行 ERC、未转 PCB

## 1. 结论

原先阻止接线的两项 P0 已闭环：CC 不再使用错误的 `D4`，而是直连具备 22V short-to-VBUS 能力的 STUSB4500；`SYS_I2C` 已物理删除 01 页的重复上拉，只保留 02 页唯一一对 4.7kΩ。两项均在画线前完成，尚未造成 PCB 或物料损失。

## 2. 审计证据与当前状态

| 项 | 结果 |
|---|---|
| EDA 基础工程 | `H0-BASE-REVA` 与 `H0-HEAD-REVA` 均存在；Base 页 01/02/04 可见，Head 页仍为 Gate 占位 |
| `01POWERUSB` | 已删除 `D4/R30/R31` 并保存；CC 与 I²C P0 已关闭，尚无可验收的完整电源网络 |
| `02-MCU-DEBUG` | 21 件已落图，`R45=10kΩ` 存在且未接线 |
| `04-AUDIO-OUT` | 存在若干未命名绿线片段；不能据此认定功放 bulk 或 Codec 网络已正确连接 |
| Head Carrier | 空白/Gate 状态符合当前 `H-IO-001` 约束；没有把未知显示或摄像头 GPIO 伪接入 |

## 3. 审计问题

| ID | 级别 | 发现 | 依据 | 必须动作 |
|---|---|---|---|---|
| `P0-01` | Closed | `D4=TPD2E2U06DRLR` 的 5.5V 耐压不适合作 CC，原方案错误 | [TPD2E2U06 datasheet](https://www.ti.com/lit/ds/symlink/tpd2e2u06.pdf)、[STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf) | 已删除 D4 并保存。STUSB4500 已对 CC 内置 22V short-to-VBUS 防护，因此 Rev A CC 为 `J_USB1.CC1/CC2 → U5.CC1/CC2` 直连；不叠加 TPD2S300，避免其额外 VPWR/VM/VBIAS/死电池链路 |
| `P0-02` | Closed | `01.R30/R31` 与 `02.R_I2C_SCL/SDA` 会形成两组 4.7kΩ 上拉候选 | `11` 第 3.1、3.6、4.1 节与 GPIO/I²C 表 | 已删除 `R30/R31` 并保存。`SYS_I2C` 唯一实体上拉为 02 页的 `R_I2C_SCL/R_I2C_SDA=4.7kΩ`；允许接入 STUSB4500、TCA9554 和 Codec |
| `P1-00` | P1 | STUSB4500 的 short-to-VBUS 能力不等于整机已完成 IEC 61000-4-2 端口级认证 | [STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf) | 首板对 CC1/CC2 进行系统级 ESD 台架验证；若不通过，基于实测选择补强，而非恢复 D4 或在当前链路随机串接保护器件 |
| `P1-01` | P1 | `04-AUDIO-OUT` 已有未命名导线片段，连接范围未能由网名或器件引脚证明 | EDA 只读画布 | 逐段复核。只有明确的 `5V_SYS`、`AUDIO_3V3A`、`GND` 或获批信号网可以保留；不明片段不得参与后续连接 |
| `P1-02` | P1 | DRV8833 的 `VCP`、`VINT`、`AISEN/BISEN`、PowerPAD 未在原清单逐脚列出，易在手工接线中遗漏 | [DRV8833 datasheet](https://www.ti.com/lit/ds/symlink/drv8833.pdf) | 按 11 第 4.5.1 节补齐；先以现有 C25…C29/R12/R13 的值核对功能位，不能按自动位号猜接 |
| `P1-03` | P1 | 两颗 TPS259470 的 `AUXOFF` 未进入功能连线表 | [TPS25947 datasheet](https://www.ti.com/lit/ds/symlink/tps25947.pdf) | Rev A 不做电源 MUX 时显式标 `NC`；不得误接成 `FLT` 或 `PG`。`FLT` 仅 pin 4，`AUXOFF` 为 pin 3 |
| `GATE-01` | 保持 Gate | 模拟麦、Codec 模拟外围、静音硬断开、FFC 方向、Head GPIO、相机、电机/编码器/限位接口仍未冻结 | `10` Gate 表、`11` 待补放表 | 不为消除 ERC 或“先跑起来”而接线 |

## 4. 接线执行顺序（审计后版本）

1. `P0-01/P0-02` 已关闭，并已同步更新 10/11 与 EDA 物料状态。
2. `01POWERUSB`：按 11 第 3.1–3.5 节，先 VBUS/TVS/P-MOS，再 TPS56637，再 TPS62132/LDO，最后两颗 eFuse；每完成一个局部网立即检查其成员。
3. `02-MCU-DEBUG`：接 Base 电源/EN/BOOT/TCA9554/R45；`SYS_I2C` 只使用唯一的 02 页上拉对。
4. `06-MOTION-IO`：先完成 DRV8833 的 VM、VCP、VINT、ISEN、nSLEEP、nFAULT，再接已批准的 UART/PWM；不接 GPIO2、限位或编码器 Gate 线。
5. `03/04-AUDIO`：只接已验证的数字电源/本地去耦与明确数字 I²S；模拟麦、AEC、Codec→功放模拟链在音频 pin mapping Gate 后接。
6. `05/07/Head`：按 FFC/线束/静音/Head Gate 逐项开放；不可通过“预接长线”绕过 Gate。
7. 各页完成后运行未连接引脚检查；所有页收敛后才运行 ERC。ERC 通过不等于 G1/G2/采购通过。

## 5. 接线前后检查卡

| 检查点 | 接线前 | 接线后 |
|---|---|---|
| CC | D4 已删除；U5 内置 22V short-to-VBUS 能力已核对 | `J_USB1.CC1/CC2` 直连 U5 对应 CC；无 5.1kΩ Rd；IEC ESD 台架项另行记录 |
| I²C | 01 `R30/R31` 已删除；02 唯一 4.7kΩ 上拉对已确认 | 每线只有一只等效上拉；地址表 `0x18/0x20/0x28/0x40` 无冲突 |
| eFuse | ILM、OVLO、EN/UVLO、DVDT、ITIMER、FLT/AUXOFF 角色已核对 | ILM 无 ADC/长线分支；AUXOFF 显式 NC；FLT 各自一只上拉 |
| DRV8833 | C25…C29/R12/R13 已按功能而非位号核对 | VM/VCP/VINT/ISEN/PowerPAD 完整；nSLEEP 默认低；nFAULT 开漏上拉 |
| 音频 | 04 的已有线段均有命名和端点证明 | PA bulk 只跨 5V_SYS/GND；BTL 输出无任一端接地 |
| Gate | 未冻结项均标记 | ERC 中只豁免有 ID 的 Gate/NC 项 |

## 6. 不在本轮处理的事项

- CC 的系统级 IEC ESD 台架结果及是否需要基于实测补强。
- Head 模组、摄像头、模拟麦、编码器、限位、静音开关和线束的最终型号/针序。
- PCB、BOM、Gerber、采购和下单。
