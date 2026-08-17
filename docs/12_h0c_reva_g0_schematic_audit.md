# 小熙 Hushlight H0C Rev A G0 原理图审计与接线收敛单

> 日期：2026-08-16
> 状态：P0-01…P0-06 与 06 页器件级 P1-02 已关闭；01 页新增外围已落位并发布 126–212 接线表。仍不代表接线完成、ERC、PCB、BOM、打板或采购放行
> 范围：审计、器件核对、EDA 定向修复与文档收敛；未运行 ERC、未转 PCB

## 1. 结论

六项 01 页 P0 已在设计与对象层面闭环：CC 直连 STUSB4500、01 不重复 I²C 上拉、U6.EN 撤销高压直连，`F1/F2=0/0`，入口保护改为 `U17=TPS259474LRPWR`，并按实际位号发布 USB/STUSB4500/主输入 eFuse 的 126–212 单点表。旧 19–22 的 U6 输入标签必须按 209–212 原位改为 `VBUS_BUCK_IN`，否则会旁路 U17。06 页 `P1-02` 保持 Closed；01 接线、ERC 与台架 Gate 仍未完成。

## 2. 审计证据与当前状态

| 项 | 结果 |
|---|---|
| EDA 基础工程 | `H0-BASE-REVA` 的 `01POWERUSB、02-MCU-DEBUG、03-AUDIO-IN、04-AUDIO-OUT、05-HEAD-LINK、06-MOTION-IO、07-CONNECTORS-TEST` 与系统页均存在；`H0-HEAD-REVA` 四页存在但尚未开始放件 |
| `01POWERUSB` | `D4/R30/R31/R32/F1/F2` 已删除；对象搜索确认 `F1=0/0、F2=0/0`。U17/D5/R46…R54/C56…C60 已落位，126–212 已发布；新增暂存件仍有重叠，须先关闭 `01-LAYOUT-01`，再完成接线和 209–212 标签更正，随后进入整页 ERC |
| `02-MCU-DEBUG` | 21 件已落图，`R45=10kΩ` 存在且未接线 |
| `04-AUDIO-OUT` | 存在若干未命名绿线片段；不能据此认定功放 bulk 或 Codec 网络已正确连接 |
| Head Carrier | 2026-08-14 逐页打开确认 `00-SYSTEM`、`01-DISPLAY-TOUCH`、`02-CAMERA-PRIVACY`、`03-FLEX-TEST` 均为 0 元件、0 网络、0 导线；空白/Gate 状态符合当前 `H-IO-001` 约束，没有把未知显示或摄像头 GPIO 伪接入 |

## 3. 审计问题

| ID | 级别 | 发现 | 依据 | 必须动作 |
|---|---|---|---|---|
| `P0-01` | Closed | `D4=TPD2E2U06DRLR` 的 5.5V 耐压不适合作 CC，原方案错误 | [TPD2E2U06 datasheet](https://www.ti.com/lit/ds/symlink/tpd2e2u06.pdf)、[STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf) | 已删除 D4 并保存。STUSB4500 已对 CC 内置 22V short-to-VBUS 防护，因此 Rev A CC 为 `J_USB1.CC1/CC2 → U5.CC1/CC2` 直连；不叠加 TPD2S300，避免其额外 VPWR/VM/VBIAS/死电池链路 |
| `P0-02` | Closed | `01.R30/R31` 与 `02.R_I2C_SCL/SDA` 会形成两组 4.7kΩ 上拉候选 | `11` 第 3.1、3.6、4.1 节与 GPIO/I²C 表 | 已删除 `R30/R31` 并保存。`SYS_I2C` 唯一实体上拉为 02 页的 `R_I2C_SCL/R_I2C_SDA=4.7kΩ`；允许接入 STUSB4500、TCA9554 和 Codec |
| `P0-03` | Closed | 原第 44/45 项以 `R32=0Ω` 把最高 12V 的 `VBUS_PD` 直接送入 TPS56637.EN，超过 EN 推荐 5.5V/绝对最大 6V | [TPS56637 datasheet](https://www.ti.com/lit/ds/symlink/tps56637.pdf) | 2026-08-14 已删除相关导线与 R32，截图确认 U6.EN 悬空；内部上拉负责默认启用。44/45 永久撤销，不得复用编号 |
| `P0-04` | Closed | 图框外重复 PTC 会误入 BOM 或被后续误接 | 2026-08-16 保存后对象搜索 | `F1=0/0、F2=0/0`；禁止恢复 2A PTC 占位 |
| `P0-05` | Closed | `F1/F2=BSMD1812-200-16V` 不适合 12V/3A 入口 | 10 第 5.2/6.1 节与 [TPS25947 datasheet](https://www.ti.com/lit/ds/symlink/tps25947.pdf) | 入口固定为 `U17=TPS259474LRPWR/C2864845`，首轮 3.5A、UVLO≈7.6V、OVLO≈15.2V；实际限流、浪涌、温升和锁存恢复保留台架 Gate |
| `P0-06` | Closed | 1–125 未覆盖 USB-C、STUSB4500 与入口 eFuse 完整外围 | [STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf)、11 第 3.5.1 节 | 已按实际位号发布 126–212；NC/DNP 不混入 A 表。用户接线、ERC 和网络成员检查仍为 G1，不回退为 P0 |
| `P1-00` | P1 | STUSB4500 的 short-to-VBUS 能力不等于整机已完成 IEC 61000-4-2 端口级认证 | [STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf) | 首板对 CC1/CC2 进行系统级 ESD 台架验证；若不通过，基于实测选择补强，而非恢复 D4 或在当前链路随机串接保护器件 |
| `P1-01` | P1 | `04-AUDIO-OUT` 已有未命名导线片段，连接范围未能由网名或器件引脚证明 | EDA 只读画布 | 逐段复核。只有明确的 `5V_SYS`、`AUDIO_3V3A`、`GND` 或获批信号网可以保留；不明片段不得参与后续连接 |
| `P1-02` | Closed | 06 页原 `C25=1µF`、`C28=100nF` 与 DRV8833 的 `VINT=2.2µF`、`VCP–VM=10nF` 要求不一致 | EDA 对象树/属性与 [DRV8833 datasheet](https://www.ti.com/lit/ds/symlink/drv8833.pdf) | 2026-08-14 已保留位号和唯一 ID，把 C25 实物器件替换为 `GRM188R71A225KE15D/C86018/2.2µF`，C28 替换为 `GRM188R71H103KA01D/C77053/10nF`，逐项属性复核并保存。06 第一批 `06-A01…A33` 已发布；GPIO2、电机、编码器、限位仍保持 Gate |
| `P1-03` | P1 | 两颗 TPS259470 的 `AUXOFF` 未进入功能连线表 | [TPS25947 datasheet](https://www.ti.com/lit/ds/symlink/tps25947.pdf) | Rev A 不做电源 MUX 时显式标 `NC`；不得误接成 `FLT` 或 `PG`。`FLT` 仅 pin 4，`AUXOFF` 为 pin 3 |
| `GATE-01` | 保持 Gate | 模拟麦、Codec 模拟外围、静音硬断开、FFC 方向、Head GPIO、相机、电机/编码器/限位接口仍未冻结 | `10` Gate 表、`11` 待补放表 | 不为消除 ERC 或“先跑起来”而接线 |

## 4. 接线执行顺序（审计后版本）

1. `P0-01/P0-02` 已关闭，并已同步更新 10/11 与 EDA 物料状态。
2. `01POWERUSB`：按 11 第 3.5.1 节完成 126–208，再执行 209–212 的 U6 输入标签原位改名；检查唯一链路 `VBUS_RAW → Q1 → VBUS_PD → U17 → VBUS_BUCK_IN → U6`，随后运行整页 ERC。
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
| eFuse | U11/U12 的 ILM、OVLO、EN/UVLO、DVDT、ITIMER、FLT/AUXOFF 及 U17 L 变体 PG/PGTH 角色已核对 | U11/U12 AUXOFF 显式 NC；U17 PG 只接 `VBUS_EFUSE_PG`；U6 输入只属于 `VBUS_BUCK_IN` |
| DRV8833 | C25/C28 的真实器件、值、封装、制造商料号和 LCSC 料号均已替换复核；PWP 引脚表已纠正 GND=pin 11 | VM/VCP/VINT/ISEN/PowerPAD 完整；nSLEEP 默认低；nFAULT 开漏上拉；pin 13 只作 AIN2 |
| 音频 | 04 的已有线段均有命名和端点证明 | PA bulk 只跨 5V_SYS/GND；BTL 输出无任一端接地 |
| Gate | 未冻结项均标记 | ERC 中只豁免有 ID 的 Gate/NC 项 |

## 6. 不在本轮处理的事项

- CC 的系统级 IEC ESD 台架结果及是否需要基于实测补强。
- Head 模组、摄像头、模拟麦、编码器、限位、静音开关和线束的最终型号/针序。
- PCB、BOM、Gerber、采购和下单。

## 7. 2026-08-14 B 项自动化审计结果

| 项 | 处理结果 | 后续边界 |
|---|---|---|
| `01POWERUSB` | A 表 1–43、46–125 已由用户接线并完成分段截图复核，44/45 永久撤销；`F1/F2=0/0`，U17 主输入 eFuse 与 USB Shield 外围已落位，126–212 已发布 | 完成 126–212，补明确 NC/DNP 标记后运行整页 ERC；台架 Gate 继续开放 |
| 双模拟麦 | `U14/U15=IM73A135V01XTSA1 / C3171831` 已落图并移入 03 图框 | `H-MIC-001` 仍负责封装朝向、声学结构、相位与增益实测 |
| 麦克风独立 LDO | `U16=TPS7A2028PDBVR / C2869847` 已落图 | 3PDT 切断位置、EN 默认态和 MIC_2V8 网络未接线 |
| LDO 去耦 | `C52/C53=GRM188R71A225KE15D / C86018`，2.2µF×2 已落图 | 连线时分别映射 U16 IN/OUT，不允许串入信号路径 |
| 麦克风本地去耦 | `C54/C55=GRM188R71H104KA93D / C77055`，100nF×2 已落图 | 每颗只服务一颗麦克风 VDD/GND，靠近器件布局 |
| 03 未命名导线 | EDA 报告 3 个导线/总线对象，未作为完成连接 | 人工逐条确认端点；不明片段删除后再按 A 表建立网络 |
| MT6701 | 不放在 Base 主板 06 页 | 两颗传感器属于独立 `H0-ENCODER-PAN/TILT-REVA` 小板；等待磁铁、气隙、安装位样件 Gate 后建小板原理图 |
| 30Pin FFC、3PDT、相机/快门、最终线束座 | 未自动落具体量产件 | 仍依赖实物针序、机构尺寸与触点逻辑；保持 `GATE-DNP`，避免错误进入 BOM |

本轮关闭的是“已经由已批准选型直接决定、无需样品尺寸才能放置”的 B 项。所有机械耦合、线束针序、磁路、相机扩展口和硬隐私触点仍保留 Gate，不能因元件库中存在候选符号而提前转为 A。
