# 小熙 Hushlight H0C Rev A 原理图人工接线交接单

> 版本：V0.5
> 日期：2026-08-13
> 状态：供人工连线；不代表 ERC 通过、可转 PCB、可打板或可采购  
> 适用工程：`Hushlight.eprj2` → `H0-BASE-REVA` / `H0-HEAD-REVA`

## 1. 结论与使用边界

2026-08-12 的嘉立创 EDA 树复核为 `H0-BASE-SCH-REVA` **122 个已保存对象**；之后已分别保存 `01POWERUSB.D4` 与 `02-MCU-DEBUG.R45`，故在下一次全树复核前按 **至少 124 个已保存对象**管理（这是图页对象计数，不是 ERC、BOM 或可生产性结论）。已落图范围包括：PD 入口、主 Buck、3.3V Buck、音频 LDO、两路 eFuse、USB-C/ESD、Base-S3 启动/I²C 扩展、ES7210/ES8311/NS4150B 去耦、Motion-C3/DRV8833 的 VM 去耦与安全默认位、旋钮/静音/调试连接器候选，以及底座/头部两端的 FFC 与 bulk 候选。`H0-HEAD-REVA` 仍只允许保留 `H-IO-001` 所需的框图、FFC Gate 与调试占位，不得虚构 AMOLED 或摄像头接口。

因此，**不能说“全部放置好了”**。本单把工作拆为三类：

| 标记 | 含义 | 执行规则 |
|---|---|---|
| `A` | 已放置且可按本单接线 | 按“源引脚 → 目标引脚/网络”连；每个网络标签改名后按 `Return` 提交 |
| `B` | 已批准但外围未放 | 先补齐本单指定的外围，再接线 |
| `BLOCKED-P0` | 已发现会改变电气安全或总线拓扑的问题 | 不接线、不转 PCB；待审计项关闭并同步更新器件/网络状态 |
| `GATE` | 器件、引脚或电气条件尚未冻结 | 只留框/测试位，不得猜测后接线 |

本单是人工在 EDA 中执行的接线说明，服从 [`10_hardware_board_design_spec.md`](10_hardware_board_design_spec.md)。发生冲突时，以 10 和器件原厂 datasheet 为准。本单不授权转 PCB、打板、采购或下单。

## 2. 每页布局：先按这个摆，再开始连

| 图页 | 从左到右 / 上到下布局 | 当前状态 |
|---|---|---|
| `00_SYSTEM` | 只放三域方框、跨页网络端口和版本/安全说明；不放功率环路 | `B`，用于总览，不承担细节连线 |
| `01POWERUSB` | 左：USB-C、ESD、STUSB4500、TVS；中：P-MOS、输入保护、TPS56637 与其输入/BOOT/电感/输出环；右上：TPS62132→`BASE_3V3`；右中：TPS7A2033→`AUDIO_3V3A`；最右：Head/Motor eFuse 与测试点 | `A+B+BLOCKED-P0`：70 个器件已落图且主件已按功能块收拢。`D4` 虽已实放，但不是合格的 CC 保护器件；`R30/R31` 与 02 页上拉冲突。PD 上拉/检测、两路 eFuse 的限流、默认关断、OVLO、软启动、故障上拉及输入去耦已确定并落图。尚未连线、ERC 或转 PCB |
| `02-MCU-DEBUG` | 中：BASE-S3 模组；左：EN/BOOT/USB；右：UART、I2C、Head SPI、Motion UART；下：TCA9554、调试口、测试点 | `A+B`：21 个器件已落图，含 Base-S3 入口 `22µF+10µF+100nF`、TCA9554、两颗 I²C 上拉、EN/BOOT 默认件及 TCA9554 中断上拉 `R45`；接口 ESD 与未分配 GPIO 仍不可猜接 |
| `03-AUDIO-IN` | 左：MIC1/MIC2 与模拟滤波；中：ES7210；右：I2S、AEC 参考和调试点；模拟电源从下方进入 | `A+B`：ES7210 数字/模拟两域各一组 `1µF+100nF` 已落图；模拟麦、偏置、滤波与完整 pin mapping 仍为 Gate |
| `04-AUDIO-OUT` | 左：ES8311；中：Codec→功放的调节/测试位；右：NS4150B、扬声器座；功放 bulk 在右下 | `A+B`：ES8311 两域去耦、NS4150B 的 `10µF+100nF+220µF` bulk、PA 默认关断/信号调节位已落图；Codec 模拟链路外围仍待 datasheet 复核 |
| `05-HEAD-LINK` | 左：BASE-S3 侧九颗 22Ω 源端串阻候选；中：30Pin FFC；右：头部端口与测试点；电源针放上，SPI/UART 放中，GND 回流针夹在信号间 | `A+GATE`：底座 FFC、9 个串阻和 `100µF+1µF+100nF` bulk 候选已放；料号、同异面、针位方向和 ESD 为 `H-FFC-001` Gate |
| `06-MOTION-IO` | 左：MOTION-C3、刷写/心跳/kill；中：DRV8833 与 VM bulk；右上：PAN 电机与编码器/限位；右下：TILT 电机与编码器/限位 | `A+B`：U8/U9、VM `10µF+100nF+470µF`、nSLEEP/nFAULT 默认位已放；电机、编码器、限位连接器和输入保护仍待 Gate |
| `07-CONNECTORS-TEST` | 左：EC11、锁定静音；中：红灯/TCA9554；右：Base/Motion/Head 服务调试口；下：按电源、USB、音频、运动分组的测试点 | `B+GATE`：EC11、红 LED/限流位、三组 1×6 服务口、扬声器/电机/编码器/限位座候选已放；锁定式静音实际型号和所有线束针序未冻结 |
| `H0-HEAD-REVA` | 左：`HEAD-S3` AMOLED 计算模组座/供电；中：摄像头、隐私灯、快门检测；右：Base FFC、头部调试口；模组天线区域留空 | `GATE`：FFC、头部 bulk 和服务口候选仅作为接口验证载体；必须先完成 `H-IO-001`，不选定扩展 GPIO、不连接摄像头 DVP |

### 2.1 页内连线规则

1. 每个跨页网使用同一网络标签，不跨页面画长线。建议名称：`VBUS_RAW`、`VBUS_PD`、`5V_SYS`、`BASE_3V3`、`AUDIO_3V3A`、`HEAD_5V`、`MOTOR_5V`、`GND`。
2. 网络标签必须落在**实际导线端点**。编辑名字后按 `Return`，再点击空白处并在右侧属性复核，不保留 `NET1`、`NET2` 等自动名。
3. `SW_5V`、`BOOT_5V`、`FB_5V` 只在 TPS56637 局部环路使用，不得跨页、不接测试排针。
4. GND 在原理图为同一 `GND` 网络；PCB 不切割主地平面。模拟隔离靠布局和受控回流实现。
5. 不在本单标为 `GATE` 的器件上“先随便接一下”。未冻结的摄像头、FFC 针位、MT6701 物理接口和模拟麦完整外围，必须等待 Gate。

## 3. `01POWERUSB`：人工逐针接线

按以下顺序执行：先入口与受控功率路径，再主 Buck、次级 Buck/LDO，最后两路 eFuse；每完成一个网络立即保存并复查网络名。

### 3.1 入口、PD 和受控功率路径

`R5=22Ω` 与 `R14=22Ω` 已在本页落图，分别作为 USB D+/D− 串阻。`VBUS_VS_DISCH=470Ω`、输入保险与 USB 数据线 ESD 均已落图；仅可按本单实际连线，不能把“已落图”当作已连通。**2026-08-13 审计结论：D4 与 R30/R31 均存在 P0 问题，见下表和 [12_h0c_reva_g0_schematic_audit.md](12_h0c_reva_g0_schematic_audit.md)，在问题关闭前不得接入 CC 或 `SYS_I2C`。**下表中 `J_USB1.VBUS` 指 Type-C 连接器所有 VBUS 触点的同名汇合网，`J_USB1.GND` 同理。

| 序号 | 源引脚 | 目标引脚 / 网络 | 状态 | 规则 |
|---:|---|---|---|---|
| 1 | `J_USB1.CC1` | `U5.STUSB4500.CC1`（pin 2） | `BLOCKED-P0` | 不得经过 D4；D4 的 5.5V 耐压不适配 CC 短接 VBUS 风险。完成 CC 专用短接 VBUS 保护 Gate 后，以替代器件的连接器侧通道接入，不并 5.1kΩ Rd |
| 2 | `J_USB1.CC2` | `U5.CC2`（pin 4） | `BLOCKED-P0` | 同上 |
| 3 | `U5.CC1DB`（pin 1） | `U5.CC1`（pin 2） | `B` | 启用 dead-battery；若明确不启用才改接 GND |
| 4 | `U5.CC2DB`（pin 5） | `U5.CC2`（pin 4） | `B` | 同上 |
| 5 | `J_USB1.VBUS` | `D1.SMBJ15A.K` + `U5.VDD`（pin 24）+ `U5.VBUS_VS_DISCH`（pin 18，经 datasheet 推荐串阻） | `A+B` | 此处为 `VBUS_RAW`；所有三者在 P-MOS 前侧 |
| 6 | `D1.SMBJ15A.A` | `GND` | `A` | 单向 TVS：阴极 VBUS、阳极地 |
| 7 | `Q1.AONR21321.S`（pins 1,2,3） | `VBUS_RAW` | `A` | 三个 Source 同网 |
| 8 | `Q1.D`（pins 5,6,7,8） | `VBUS_PD` | `A` | 四个 Drain 同网，去输入保险/主 Buck |
| 9 | `U5.VBUS_EN_SNK`（pin 16） | `R1.100Ω.1` | `A` | 高压开漏控制；禁止接到 MCU GPIO |
| 10 | `R1.100Ω.2` | `Q1.G`（pin 4） | `A` | `PD_GATE` 网 |
| 11 | `R2.100k.1` | `Q1.G`（pin 4） | `A` | Gate–Source 默认关断 |
| 12 | `R2.100k.2` | `Q1.S`（pins 1–3） | `A` | 接 `VBUS_RAW` |
| 13 | `D3.BZT52C15.K` | `Q1.S`（pins 1–3） | `A` | 15V 齐纳 Vgs 钳位，阴极接 Source |
| 14 | `D3.BZT52C15.A` | `Q1.G`（pin 4） | `A` | 阳极接 Gate |
| 15 | `U5.POWER_OK3`（pin 14） | `TP_PD_PDO3_OK_N` + 3.3V 上拉；预留跨页网 `PD_PDO3_OK_N` | `GATE` | 此轮不接 BASE-S3。待在 10 中冻结确切 GPIO 后，才接入全性能准入状态机；不直接驱动功率器件 |
| 16 | `U5.SCL`（pin 7） | `BASE-S3.GPIO18 / SYS_I2C_SCL` | `BLOCKED-P0` | 先决定唯一一对总线 4.7kΩ 上拉；不得同时接入 `R30/R31` 和 02 页 `R_I2C_SCL/SDA` |
| 17 | `U5.SDA`（pin 8） | `BASE-S3.GPIO17 / SYS_I2C_SDA` | `BLOCKED-P0` | 同上 |
| 18 | `U5.ALERT`（pin 19） | `TCA9554.P3 / PD_INT_N` + 3.3V 上拉 | `B` | 开漏；若不做诊断，仍保留测试点 |
| 19 | `U5.ADDR0`（pin 12）、`U5.ADDR1`（pin 13） | `GND` | `B` | 形成既定候选地址 `0x28` |
| 20 | `U5.GND`（pin 10）和 EP | `GND` | `B` | EP 完整接地铜 |
| 21 | `U5.VREG_1V2`（pin 21） | 1µF → `GND` | `B` | 仅去耦，不给外部负载 |
| 22 | `U5.VREG_2V7`（pin 23） | 1µF → `GND` | `B` | 仅去耦，不给外部负载 |
| 23 | `U5.VSYS`（pin 22） | `GND` | `B` | Rev A 无独立系统备用供电，不得悬空 |
| 24 | `J_USB1.D+` / `D−` | `D2.TPD2EUSB30A` 对应受保护通道 → 22Ω 串阻 → `BASE-S3.GPIO20/USB_DP`、`GPIO19/USB_DN` | `A+B` | 差分对同层、90Ω；D2 的 GND 脚最短到地 |

### 3.2 12V→5.1V 主 Buck：TPS56637

`TPS56637` 引脚号以 RPA-10 为准。`C1/C2/C3/C4/L1/R3/R4/C5…C8` 与 `R32=0Ω`（EN 默认配置位）已放置；连线完成后，用局部网络标签而不是穿越整个页面的长线。

| 序号 | 源引脚 | 目标引脚 / 网络 | 状态 | 规则 |
|---:|---|---|---|---|
| 1 | `U6.VIN`（pin 8） | `VBUS_PD` | `A` | 通过输入保险/限流后；VIN 近端汇合 |
| 2 | `C1.1`、`C2.1`、`C3.1` | `VBUS_PD` | `A` | 两颗 10µF + 一颗 100nF 都在 VIN 近端 |
| 3 | `C1.2`、`C2.2`、`C3.2` | `GND` | `A` | 回到 U6 PGND 近端地；不是绕到音频地 |
| 4 | `U6.PGND`（pin 9） | `GND` | `A` | 与输入/输出功率回路最短；PCB 与 AGND 单点汇合 |
| 5 | `U6.AGND`（pin 3） | `GND` | `A` | 接安静地，靠 FB 下端；不串大电流回流 |
| 6 | `U6.SW`（pin 6） | `L1.1` + `C4.2` | `A` | 网络名 `SW_5V`；铜皮/导线最短，禁止接测试点 |
| 7 | `U6.BOOT`（pin 7） | `C4.1` | `A` | 网络名 `BOOT_5V`；C4 为 100nF，只跨 BOOT–SW |
| 8 | `L1.2` | `5V_SYS` | `A` | 输出电感后才是 5V_SYS |
| 9 | `C5.1`、`C6.1`、`C7.1`、`C8.1` | `5V_SYS` | `A` | 四颗 22µF 并联，靠 L1 输出 |
| 10 | `C5.2`、`C6.2`、`C7.2`、`C8.2` | `GND` | `A` | 与 U6 PGND 的高电流回路最短 |
| 11 | `R3.75k.1` | `5V_SYS` | `A` | 反馈上端，走线从 COUT 正端 Kelvin 取样 |
| 12 | `R3.75k.2` | `U6.FB`（pin 2）+ `R4.10k.1` | `A` | 网络名 `FB_5V`；远离 SW |
| 13 | `R4.10k.2` | `GND` | `A` | 接 U6 AGND 邻近的安静地 |
| 14 | `U6.EN`（pin 1） | `VBUS_PD`，经待补放 `R_EN0=0Ω` 默认位 | `B` | 本轮唯一默认实现；若后续需要 UVLO 分压，另开 Gate 并替换 0Ω，不在本轮并列两种接法 |
| 15 | `U6.MODE`（pin 10） | 悬空（默认 FCCM） | `A` | 不放普通网络标签；预留 `0Ω DNP → GND` 改 Eco-mode |
| 16 | `U6.PG`（pin 4） | `5V_SYS_PG`，再经 100k 上拉到 `BASE_3V3` | `B` | 开漏输出；BASE-S3 读取启动状态 |
| 17 | `U6.NC`（pin 5） | 不连接 | `A` | 必须标非连接，不接 GND |

### 3.3 5V→BASE_3V3：TPS62132

已放 `L2` 候选、`C_3V3_IN_10U`、`C_3V3_IN_100N`、`C_3V3_OUT_22U`，以及 `C_SS_3V3=3.3nF/25V/0603`（嘉立创 `C2838745`）；仍需确认 `R_PG3V3=100k`。这里使用**功能位名**，避免同一工程的全局位号与 `02-MCU-DEBUG` 中的 C9…C13 混淆。固定 3.3V 型的 `FB` 不使用分压。`R5` 已被占用为 USB 22Ω 串阻，不能再把它当作 PG 上拉。

| 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|
| `U7.AVIN`（pin 10）、`PVIN`（pins 11,12） | `5V_SYS` | `C_3V3_IN_10U/C_3V3_IN_100N` 正端同点、近端 |
| `C_3V3_IN_10U.2`、`C_3V3_IN_100N.2` | `GND` | 回 U7 PGND/EP 邻近 |
| `U7.SW`（pins 1,2,3） | `L2.1` | 仅局部 `SW_3V3` |
| `L2.2` | `BASE_3V3` | 输出节点 |
| `C_3V3_OUT_22U.1`、`U7.VOS`（pin 14） | `BASE_3V3` | 输出采样与输出电容同一安静节点 |
| `U7.FSW`（pin 7） | `FSW_3V3_CFG` 测试焊盘/配置位 | `GATE`：不在本轮把 FSW 接到 `BASE_3V3` 或 GND；先完成 datasheet 复核和 EMI 决策，再指定唯一连接 |
| `C_3V3_OUT_22U.2` | `GND` | 输出电容回路最短 |
| `U7.FB`（pin 5） | `U7.AGND`（pin 6） | TPS62132 固定输出型要求 |
| `U7.DEF`（pin 8） | `GND` | 保持标称 3.3V，不要拉高到 +5% |
| `U7.SS/TR`（pin 9） | `C_SS_3V3.1`；`C_SS_3V3.2→GND` | 首轮软启动位 |
| `U7.EN`（pin 13） | `5V_SYS` | 先直连；如需由 `5V_SYS_PG` 延迟，再改为受控位 |
| `U7.PG`（pin 4） | `BASE_3V3_PG` + `R_PG3V3.1`；`R_PG3V3.2→BASE_3V3` | 开漏上拉 |
| `U7.AGND`（pin 6）、`PGND`（pins 15,16）、EP | `GND` | EP 必焊接地 |

### 3.4 5V→AUDIO_3V3A：TPS7A2033

已放 `C_LDO_IN_2U2`、`C_LDO_OUT_2U2` 候选；`R_PG_AUDIO=100k` 为可选上拉/测试位。严格按 `TPS7A2033PDBVR` 的实际符号 pin name 落图；若 EDA 符号与 datasheet 不一致，停下并记录，不以猜测编号连线。

| 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|
| `U10.IN` | `5V_SYS` + `C_LDO_IN_2U2.1` | 音频电源入口 |
| `C_LDO_IN_2U2.2` | `GND` | 近端 |
| `U10.OUT` | `AUDIO_3V3A` + `C_LDO_OUT_2U2.1` | 仅 ES7210、ES8311、麦克风模拟敏感域 |
| `C_LDO_OUT_2U2.2`、`U10.GND` | `GND` | 不切割地平面 |
| `U10.EN` | `5V_SYS` | 本轮唯一默认连接；`AUDIO_EN` 仅保留 DNP 配置位，需单独 Gate 后才替换 |

### 3.5 Head / Motor eFuse：TPS259470

U11 与 U12 使用相同 pinout；`EN/UVLO`、`OVLO`、`ILM`、`DVDT`、`ITIMER` 的首轮设定器件均已落图，不能悬空。首轮限流按 TI 公式 `R_ILM≈3334/I_LIMIT` 取 `R33=1.69kΩ`（Head，约 1.97A）与 `R34=1.10kΩ`（Motor，约 3.03A）。这些是样机初始值，`H-PWR-001` 仍须以实测浪涌、热、动作负载与误保护结果冻结。

| 器件 | 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|---|
| U11 Head | `IN`（pin 5） | `5V_SYS` | eFuse 输入近端 10µF + 100nF |
| U11 Head | `OUT`（pin 6） | `HEAD_5V` → FFC pins 5–8 | FFC 两端另放 47–100µF + 1µF + 100nF |
| U11 Head | `EN/UVLO`（pin 1） | `HEAD_PWR_EN` + 默认下拉/分压 | BASE-S3 GPIO16 控制；不上电默认关闭 |
| U11 Head | `FLT`（pin 4） | `HEAD_OC_N` → TCA9554.P4 + 3.3V 上拉 | 开漏低有效 |
| U11 Head | `ILM`（pin 9） | `R33=1.69kΩ → GND` | 初始限流约 1.97A |
| U11 Head | `DVDT`（pin 7） | `C48=2.2nF → GND` | 首轮软启动位 |
| U11 Head | `ITIMER`（pin 10） | `C49=2.2nF → GND` | 首轮过流计时位；台架实测后冻结 |
| U11 Head | `OVLO`（pin 2）、`GND`（pin 8） | OVLO 分压到 `5V_SYS`/GND；GND→GND | OVLO 不悬空 |
| U12 Motor | `IN`（pin 5） | `5V_SYS` | Motor 域独立输入去耦 |
| U12 Motor | `OUT`（pin 6） | `MOTOR_5V` → DRV8833 VM | U12 后先到 470µF + 10µF + 100nF bulk |
| U12 Motor | `EN/UVLO`（pin 1） | `MOTOR_PWR_EN` + 默认下拉/分压 | 默认关闭；仅限位/心跳正常后允许 |
| U12 Motor | `FLT`（pin 4） | `MOTOR_OC_N` → TCA9554.P5 + 3.3V 上拉 | 开漏低有效 |
| U12 Motor | `ILM`（pin 9） | `R34=1.10kΩ → GND` | 初始限流约 3.03A |
| U12 Motor | `DVDT`（pin 7）、`OVLO`（pin 2）、`GND`（pin 8） | `C50=2.2nF → GND`；OVLO 与 GND 同 U11 对应规则 | `OVLO`、`ILM` 不得浮空 |
| U12 Motor | `ITIMER`（pin 10） | `C51=2.2nF → GND` | 首轮过流计时位；台架实测后冻结 |

### 3.6 2026-08-13 已补齐元件清单（必须按功能名接线）

下表对应 `01POWERUSB` 当前 70 个器件的本轮新增/冻结项。位号已经在 EDA 中复核；接线时同时核对“功能”和“值”，不可只凭自动位号推断用途。`C52=2.2nF` 为此前已存在的页面元件，不属于本轮两路 eFuse 的计时/斜率设定。

| 功能块 | 位号 | 已选器件/值 | 连接意图 |
|---|---|---|---|
| PD VBUS 检测/泄放 | `R29` | `1206W4F4700T5E`，470Ω，250mW | `VBUS_RAW → U5.VBUS_VS_DISCH`；按 STUSB4500 参考应用 |
| Type-C CC ESD | `D4` | `TPD2E2U06DRLR`，SOT-553-5，LCSC `C1972959` | `BLOCKED-P0`：器件仅 5.5V VRWM，不能用于可能短接 20V/22V VBUS 的 CC；保留实物位置供审计，**不得接线或计入 Rev A CC 保护 BOM** |
| PD I²C | `R30`、`R31` | `0603WAF4701T5E`，4.7kΩ | `BLOCKED-P0`：与 02 页既有 I²C 上拉冲突；在唯一上拉对批准前不接入 `SYS_I2C`。建议保留 02 页逻辑对，本对 DNP/改位须审批 |
| 主 Buck 使能 | `R32` | `0603WAF0000T5E`，0Ω | `VBUS_PD → U6.EN` 的唯一默认配置位 |
| Head 限流 | `R33` | `0603WAF1691T5E`，1.69kΩ，1% | `U11.ILM → GND`，首轮约 1.97A |
| Motor 限流 | `R34` | `0603WAF1101T5E`，1.10kΩ，1% | `U12.ILM → GND`，首轮约 3.03A |
| 分支使能保护 | `R35`、`R36` | `0603WAF1001T5E`，1kΩ | Base GPIO 至 `U11/U12.EN` 串联保护位 |
| 默认关断 | `R37`、`R38` | `0603WAF1003T5E`，100kΩ | `U11/U12.EN → GND`，掉电/复位默认关闭 |
| Head/Motor OVLO 下臂 | `R39`、`R40` | `0603WAF1003T5E`，100kΩ | `U11/U12.OVLO → GND` |
| Head/Motor OVLO 上臂 | `R41`、`R42` | `0603WAF3903T5E`，390kΩ | `5V_SYS → U11/U12.OVLO`；首轮上升阈值约 5.88V |
| eFuse 故障读取 | `R43`、`R44` | `0603WAF1002T5E`，10kΩ | `U11/U12.FLT → BASE_3V3` 开漏上拉，各一颗 |
| Head/Motor eFuse 输入 bulk | `C44`、`C45` | `GRM31CR71E106KA12L`，10µF，25V | 各自 `IN → GND`，贴近 eFuse 输入脚 |
| Head/Motor eFuse 高频去耦 | `C46`、`C47` | `GRM188R71H104KA93D`，100nF，50V | 各自 `IN → GND`，贴近 eFuse 输入脚 |
| Head 斜率/计时 | `C48`、`C49` | `GRM1885C1H222JA01D`，2.2nF，50V | 分别 `U11.DVDT/ITIMER → GND` |
| Motor 斜率/计时 | `C50`、`C51` | `GRM1885C1H222JA01D`，2.2nF，50V | 分别 `U12.DVDT/ITIMER → GND` |

本表代表“器件选择与落图已完成”，不代表这些网络已经连通，也不取消 `H-PWR-001` 的实测 Gate。

## 4. 其余页：现在只接批准的核心网络

本节只列当前可由已批准 GPIO/接口表直接推出的连接；凡需完整器件外围或实物针脚证据的部分均保留为补放或 Gate。

### 4.1 `02-MCU-DEBUG`：BASE-S3

`U1=ESP32-S3-WROOM-1-N16R8` 的 GPIO 只能按 10 第 8.1 节使用。Base-S3 的 `C9=10µF`、`C10=22µF`、`C11=100nF`、EN/BOOT 默认件及 TCA9554 去耦均已落图，人工按下表接到 `BASE_3V3/GND` 与相应启动节点；USB/UART 服务口的防护与未分配 GPIO 仍不得猜接。天线禁布区不画任何连接器/铜皮含义的占位。`SYS_I2C` 的实体上拉只允许一对：当前建议保留本页 `R_I2C_SCL/SDA`，01 页 `R30/R31` 在 P0-02 关闭前不得并入。

`R45=R_IOEXP_INT=0603WAF1002T5E / 10kΩ / C25804` 已实放但未接线；它只能作为 `U13.TCA9554.INT` 的唯一上拉，接法为 `U13.INT → R45.1`，`R45.2 → BASE_3V3`。不得在其他图页再增加并联上拉。

| U1 引脚/信号 | 连接对象 | 约束 |
|---|---|---|
| `3V3` | `BASE_3V3`，近端 `22µF + 10µF + 100nF` 至 GND | 具体电源脚按模组 datasheet 全部接齐 |
| `GPIO19/USB_DN`、`GPIO20/USB_DP` | `01POWERUSB` 的 USB 串阻后端 | 90Ω 差分；不得与 PD I2C 混接 |
| `GPIO43/U0TXD`、`GPIO44/U0RXD` | `J_BASE_DBG.RX/TX` | 交叉定义并在调试座丝印标清 |
| `GPIO17/18` | `SYS_I2C_SDA/SCL` → ES7210、ES8311、TCA9554、STUSB4500 | 仅一对 4.7k 上拉；先查地址表 |
| `GPIO21/38` | `MOTION_UART_TX/RX` → U8 GPIO18/19 | TX→RX，RX←TX；1Mbps、串阻位 |
| `GPIO9–16`、`GPIO41/42` | Head FFC pins 9–20 的同名网络 | 按 10 的 30Pin 表；源端串阻/默认上下拉 |
| `GPIO39` | `MUTE_SENSE` | 硬件默认静音，开关断线不能变为采集允许 |
| `GPIO47` | `MOTION_KILL_N` | 默认下拉，未运行即关闭驱动 |
| `GPIO48` | `PA_ENABLE` | 默认下拉，先关功放再关 Codec |

#### 4.1.1 Base-S3 启动、复位、I2C 与服务口：引脚到引脚表

以下是该页已落图的 `R_EN_BASE`、`C_EN_BASE`、`R_BOOT_BASE`、`C_IOEXP_BASE` 等外围应执行的唯一默认接法；位号以 EDA 实际标注为准，功能名优先。不得因全局自动位号变化而改动功能/数值。

| 功能件/源引脚 | 目标引脚 / 网络 | 装配或接线约束 |
|---|---|---|
| `U1.EN` | `R_EN_BASE.1` + `C_EN_BASE.1` + `SW_RESET.1` | 同一 `EN_BASE` 节点；不要直接把 EN 绑死到 3.3V |
| `R_EN_BASE.2` | `BASE_3V3` | 10kΩ 上拉候选；必须靠模组 |
| `C_EN_BASE.2`、`SW_RESET.2` | `GND` | `C_EN_BASE=1µF` 复位 RC；复位开关按下拉低 EN |
| `U1.GPIO0/BOOT_N` | `R_BOOT_BASE.1` + `SW_BOOT.1` | 启动绑定节点；不接普通外设 |
| `R_BOOT_BASE.2` | `BASE_3V3` | 10kΩ 上拉候选 |
| `SW_BOOT.2` | `GND` | 按下进入下载条件；与 EN 的操作时序由调试 SOP 规定 |
| `U13.TCA9554.VCC` | `BASE_3V3` + `C_IOEXP_BASE.1` | `C_IOEXP_BASE=100nF`，去耦贴近 VCC |
| `U13.TCA9554.GND`、`C_IOEXP_BASE.2` | `GND` | 不经由音频敏感域串接 |
| `U13.TCA9554.SCL` | `U1.GPIO18 / SYS_I2C_SCL` + `R_I2C_SCL.1` | 开漏总线；只保留一颗对应上拉 |
| `R_I2C_SCL.2` | `BASE_3V3` | 4.7kΩ 起始值，线长/电容实测后可调整 |
| `U13.TCA9554.SDA` | `U1.GPIO17 / SYS_I2C_SDA` + `R_I2C_SDA.1` | 与 ES7210、ES8311、STUSB4500 共用总线 |
| `R_I2C_SDA.2` | `BASE_3V3` | 4.7kΩ 起始值；不得再为每个从设备重复上拉 |
| `U13.TCA9554.A0/A1/A2` | `GND` | 固定候选地址 `0x20`；若地址表变更，必须重开 Gate |
| `U13.TCA9554.INT` | `U1.GPIO40 / IOEXP_IRQ_N` + 10kΩ 上拉至 `BASE_3V3` | 开漏低有效；10k 上拉件可在本页或中断源页落图，但只能有一处 |
| `U13.P0` | `ENC1.SW` | 旋钮按压输入；开关另一端 `GND` |
| `U13.P1` | `MUTE_LED_AUX` | 只作辅助状态，不得成为静音红灯唯一驱动路径 |
| `U13.P3` | `PD_INT_N` | STUSB4500 `ALERT` 的诊断输入，保留 3.3V 上拉 |
| `U13.P4`、`U13.P5` | `HEAD_OC_N`、`MOTOR_OC_N` | 分别来自两颗 eFuse 的 `FLT`；各自独立上拉 |
| `J_BASE_DBG.3V3/GND` | `BASE_3V3/GND` | 服务盖板内部口；不允许用于向未隔离外设供电 |
| `J_BASE_DBG.RX` | `U1.GPIO43/U0TXD` | 调试座用“RX”表示主机接收端，丝印必须注明交叉方向 |
| `J_BASE_DBG.TX` | `U1.GPIO44/U0RXD` | 同上；调试器 TX 接此点 |
| `J_BASE_DBG.EN/BOOT` | `EN_BASE` / `BOOT_N` | 仅恢复和烧录；不得与业务 GPIO 共用 |

### 4.2 `03-AUDIO-IN`：ES7210 与双模拟 MEMS

已放置的 `C14=1µF`、`C15=100nF` 为 ES7210 数字域去耦；`C16=100nF`、`C17=1µF` 为模拟域去耦。每一对必须紧贴对应电源脚：`.1→` 相应电源、`.2→GND`。**不要**把这四颗电容接到 MIC 信号线上，也不要把数字域去耦替代模拟域去耦。

ES7210 的模拟输入模式、MICBIAS、AC 耦合/偏置和 AEC 参考输入必须按 Korvo-2 V3.1 + ES7210 datasheet 逐脚核对后再连。当前不写伪精确的 MIC 脚号。

| 可立即建立的网络 | 连接 | 条件 |
|---|---|---|
| `I2S_MCLK/BCLK/LRCK` | U1 GPIO4/5/6 → U4 对应数字时钟脚 | U4 符号与 datasheet pin name 一致后 |
| `ADC_SDOUT` | U4 数字数据输出 → U1 GPIO7 | 方向单向 |
| `AUDIO_3V3A` / `GND` | U4 模拟电源、双麦供电和本地去耦 | MIC 料号冻结前先只留去耦焊盘 |
| `AEC_REF` | ES8311 DAC 模拟输出、功放前分支 → ES7210 参考输入 | 禁止从 NS4150B 喇叭输出取样 |

待 `H-MIC-001` 通过后，人工将 `MIC1/MIC2` 的同型号模拟 MEMS、各自的偏置/RC/ESD 与 `U4` 的实际模拟脚按 datasheet 原理图逐针补齐；在此之前，任何悬空的 `MICBIAS/MICxP/MICxN` 都应显式标为 Gate，不能为了消灭 ERC 错误而接地。

### 4.3 `04-AUDIO-OUT`：ES8311、NS4150B 与扬声器

已放置的去耦/储能件按功能接线，自动位号不得替代功能核对：`C18=1µF`、`C19=100nF` 只服务 ES8311 数字域；`C20=1µF`、`C21=100nF` 只服务 ES8311 模拟域；`C22=10µF`、`C23=100nF`、`C24=220µF` 并联在 `U2` 的 `5V_SYS` 功放入口与 `GND` 之间。每组回流在所属 IC 电源脚附近闭合。

审计时本页已存在未命名的绿色导线片段。它们尚未构成已审核网络，且不能作为上表电容已正确并联或已连 U2/U3 的证据；在给 U2/U3 增加任何导线前，必须先逐段确认其一端为指定电源网、另一端为 `GND`，否则将该段撤回到未连接状态后再按本节连线。

| 源 | 目标 | 规则 |
|---|---|---|
| U1 `I2S_MCLK/BCLK/LRCK`、`DAC_DSDIN` | U3 ES8311 相应 I2S pins | 共享时钟；先核对符号 pin name |
| U3 DAC 模拟输出 | U2 NS4150B 输入，经 0Ω/RC/隔直 DNP 位与 TP11 | AEC 参考在此处分支 |
| U1 GPIO48 `PA_ENABLE` | U2 使能脚 | 10k 下拉，默认关功放 |
| U2 BTL 输出 | `J_SPK1.SP+ / SP−` | 两根都不接地；靠连接器、成对走线 |
| `5V_SYS` | U2 功放电源入口 + `220µF + 10µF + 100nF` 至 GND | 功放 bulk 靠 U2；不经 AUDIO_3V3A |

### 4.4 `05-HEAD-LINK`：30Pin FFC

底座及 Head Carrier 两端均已放置 `H-FFC-001` 候选与 `100µF+1µF+100nF` 头部 bulk 候选；底座侧另放九颗 `22Ω` 源端串阻候选。候选料号、翻盖方向、同面/异面和 pin-1 方向在 `H-FFC-001` 通过前都不可冻结，故此处只按**信号名称**接表，位号以当前 EDA 实物为准。

| FFC pin | 底座端接线 | Head Carrier 端接线 | 串阻/默认约束 |
|---:|---|---|---|
| 1–4、10、14、29–30 | `GND` | `GND` | 所有地针同网；不可省略中间回流针 |
| 5–8 | `U11.OUT / HEAD_5V` | `HEAD_5V` + 本地 bulk | 不跨 FFC 传 eFuse 设定或故障电流 |
| 9 | `U1 → HEAD_SPI_SCLK` | `HEAD_SPI_SCLK` | 22Ω 源端候选 |
| 11 | `U1 → HEAD_SPI_MOSI` | `HEAD_SPI_MOSI` | 22Ω 源端候选 |
| 12 | `HEAD_SPI_MISO → U1` | `HEAD_SPI_MISO` | 22Ω 源端候选，须位于实际驱动端 |
| 13 | `U1 → HEAD_SPI_CS_N` | `HEAD_SPI_CS_N` | 22Ω 候选；默认上拉待 Head 模组 GPIO Gate |
| 15 | `HEAD_IRQ_N → U1` | `HEAD_IRQ_N` | 开漏优先；上拉归属在 `H-IO-001` 冻结 |
| 16 | `HEAD_READY → U1` | `HEAD_READY` | 不作为直接上电判据，须由底座状态机读取 |
| 17 | `U1 → HEAD_RESET_N` | `HEAD_RESET_N` | 22Ω 候选；默认上拉待 Gate |
| 18 | `U1 GPIO16 → U11.EN/UVLO` 的本地控制网 | 仅状态/接口名，不驱动负载 | 不把 eFuse 电流、ILIM 或 OUT 经此针传递 |
| 19–20 | `U1 TX/RX` | `HEAD_UART_RX/TX` | TX/RX 交叉；各留 22Ω 候选 |
| 21–22 | `CAM_ACTIVE_LED_SENSE`、`SHUTTER_CLOSED_N` → U1 | 对应 Head 状态检测 | 未选定头部模组/快门件前只接到 Gate 测试位 |
| 23 | `HEAD_TEMP_ALERT_N` | DNP/测试位 | Rev A DNP，不能被普通 GPIO 占用 |
| 24 | `U1 → HEAD_BOOT_N` | `HEAD_BOOT_N` | 仅服务模式；默认上拉待 Gate |
| 25–26 | `SPARE_DIFF_P/N` | 成对 DNP | 不能拆成普通单端杂线 |
| 27–28 | `SPARE_GPIO0/1` | DNP/测试位 | 各留 22Ω 串阻候选 |

摄像头 DVP 和 AMOLED QSPI 不经过这条 FFC。

### 4.5 `06-MOTION-IO`：MOTION-C3 与 DRV8833

| 源 | 目标 | 状态/规则 |
|---|---|---|
| U8 GPIO0/1 | U9 DRV8833 `AIN1/AIN2` | `A` 核心网络；0/1 均预留串阻 |
| U8 GPIO3 | U9 `BIN2` | `A`；预留源端串阻 |
| U8 GPIO2 | U9 `BIN1` | `GATE`；GPIO2 是绑带脚，复核启动电平与电阻网络后才允许接 |
| U9 `AOUT1/AOUT2` | `J_MOTOR_P.1/.2` | `B`，连接器防反插 |
| U9 `BOUT1/BOUT2` | `J_MOTOR_T.1/.2` | `B` |
| U12 `MOTOR_5V` | U9 `VM` + 近端 `10µF + 100nF` + Motor bulk | `B`，不从 BASE_3V3 取电 |
| U8 GPIO21 | U9 `nSLEEP` | `A`；10k 下拉，硬件默认关电机 |
| U9 `nFAULT` | U8 GPIO10 + 3.3V 上拉 | `B`，开漏/低有效按 datasheet |
| U8 GPIO4/5、6/7 | PAN/TILT 编码器 `A/B` | `GATE`，MT6701 实测输出制式后冻结 |
| U8 GPIO8/9 | PAN/TILT 常闭限位回路 | `GATE`，绑带电平、断线安全和 RC/施密特先验证 |
| U1 GPIO21/38 | U8 GPIO18/19 | `A`，Motion UART TX↔RX；共地 |
| U1 GPIO47 | U8 安全停机/驱动禁止逻辑 | `B`，不依赖串口超时单独保安全 |

#### 4.5.1 `U9=DRV8833PWP`：补充逐脚约束

以下连接不依赖电机、编码器或限位的最终型号，可在核对现有 `C25…C29/R12/R13` 的实际值与功能后建立。按 `DRV8833PWP` 的 HTSSOP 引脚号执行；不要把 TSSOP `PW` 的引脚号混入。

| 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|
| `U9.VM`（pin 10） | `MOTOR_5V` + `C_VM_10U.1` | `10µF` 陶瓷贴近 VM；Motor bulk 仍在 U12 后端 |
| `C_VM_10U.2`、`U9.GND`（pin 13）、PowerPAD | `GND` | GND 与 PowerPAD 都必须接地；PowerPAD 不可仅作散热悬空 |
| `U9.VCP`（pin 9） | `C_VCP_10N.1`；`C_VCP_10N.2 → MOTOR_5V` | `10nF/16V X7R`，只跨 VCP–VM |
| `U9.VINT`（pin 12） | `C_VINT_2U2.1`；`C_VINT_2U2.2 → GND` | `2.2µF/6.3V`，只作内部 LDO 去耦 |
| `U9.AISEN`（pin 1）、`U9.BISEN`（pin 4） | `GND` | Rev A 不实施绕组电流调节时直接接 GND；若改用电流采样电阻，必须重开 `H-MOT-001` |
| `U9.nFAULT`（pin 6） | `U8.GPIO10` + `R_FAULT_PU.1`；`R_FAULT_PU.2 → BASE_3V3` | 开漏低有效；`R_FAULT_PU=10kΩ`，不得由 MCU 推高 |
| `U9.nSLEEP`（pin 15） | `U8.GPIO21` + `R_SLEEP_PD.1`；`R_SLEEP_PD.2 → GND` | `R_SLEEP_PD=10kΩ`；C3 复位时保持睡眠 |
| `U9.AIN1/AIN2`（pins 14/13）、`BIN1/BIN2`（pins 7/8） | `U8.GPIO0/1/2/3` | GPIO2→BIN1 仍为 Gate；其余按 4.5 表并留源端串阻 |
| `U9.AOUT1/AOUT2`（pins 16/2） | `J_MOTOR_P.1/.2` | 不接地，不加外部反灌电源 |
| `U9.BOUT1/BOUT2`（pins 5/3） | `J_MOTOR_T.1/.2` | 同上 |

### 4.6 `07-CONNECTORS-TEST` 与 Head Carrier

- EC11（`C202365` 候选）：`A/B → U1 GPIO1/2`，`SW → TCA9554.P0`，共同端接 GND；A/B 以 RC/软件消抖二选一，不能双重造成迟滞。
- 静音锁定开关：已放 `SS-12D07` 候选及红 LED/`1kΩ` 限流候选，但该开关是否满足锁定、触点数、额定电流和机械开孔仍为 Gate。通过后，一组触点硬件关闭麦克风有效供电/ES7210 MICBIAS，另一组触点形成 `MUTE_SENSE → U1 GPIO39`；红灯由独立硬件路径点亮，TCA9554.P1 只读/辅助显示。
- 服务口：Base、Motion、Head 均已放一组 `1×6` 候选。针序固定为 `GND / 3V3 / TX / RX / EN(or RESET) / BOOT`；Base 采用 U1 GPIO43/44，Motion/Head 仅在各自模块 datasheet 核对后接入。扬声器、PAN/TILT 电机、两路编码器和两路限位均已放 VH 系候选座，具体壳体/线束针序冻结前不得把相邻针位短接。
- Head Carrier：头部计算单元固定为 `HEAD-S3`。只在完成 `H-IO-001` 后，根据 Waveshare 34Pin 原理图把 `HEAD_SPI_*`、`HEAD_UART_*`、`HEAD_READY`、`SHUTTER_CLOSED_N` 接到已验证的 `HEAD-S3` 扩展脚；当前禁止把摄像头直接并到未知 GPIO。

## 5. 人工连线后的检查顺序

1. 对每页执行“未连接引脚”检查：NC、DNP 和刻意悬空项必须有明确标识；其余不能悬空。
2. 在 `01POWERUSB` 检查四个局部网：`SW_5V` 只连 U6.6/L1.1/C4.2；`BOOT_5V` 只连 U6.7/C4.1；`FB_5V` 只连 U6.2/R3.2/R4.1；`5V_SYS` 在 L1 后。
3. 逐项比对 GPIO 表、I2C 地址表、FFC 30Pin 表和 Motion UART 对接表。
4. 保存工程，导出原理图 PDF 和 BOM 草案；运行 ERC。
5. ERC 每一项错误必须记录为“修复 / 明确豁免 / 待 Gate”，不能直接忽略。
6. 通过 G1 前不执行“原理图转 PCB”，不生成制造文件，不采购。

## 6. 待补放清单（连线前必须可见）

| 页 | 必补项目 | 停止条件 |
|---|---|---|
| `01POWERUSB` | U6 EN/PG、TPS62132 `FSW/PG` 的最终配置与 Gate 复核 | CC 专用 short-to-VBUS 保护替代方案、唯一 PD I²C 上拉、VBUS 放电限流、输入保险/限浪涌位、TPS62132 `SS` 与 eFuse `ILIM/DVDT/OVLO/ITIMER` 设定件均已落图或已批准；P0/Gate 未关闭不得宣称电源完整 |
| `02-MCU-DEBUG` | USB/UART 保护及最终服务口针序 | Base-S3 bulk/去耦、TCA9554 本体/去耦、两颗 I²C 上拉、EN/BOOT 默认件及 INT 唯一上拉 `R45` 已放；仍须复核绑带和 PSRAM 占脚 |
| `03/04-AUDIO` | 两只同型号模拟 MEMS、ES7210/ES8311/NS4150B 的 datasheet 级模拟外围、麦静音硬断链 | 四组 codec 去耦、功放 bulk 和 PA 调整位已放；`H-MIC-001` 与音频 pin mapping 未通过不得接模拟脚 |
| `05-HEAD-LINK` | 30Pin FFC 实际料号/朝向、ESD、Head GPIO 上拉及 pin-1 机械验证 | FFC、九颗 22Ω、底座/头部 bulk 已放；`H-FFC-001` 通过前不得冻结线束 |
| `06-MOTION-IO` | 电机/编码器/限位连接器针序、输入保护、编码器与限位滤波/施密特 | VM bulk 与 nSLEEP/nFAULT 默认位已放；`H-MOT-001`、`H-ENC-001` 未通过不得接绑带/限位 Gate 脚 |
| `07-CONNECTORS-TEST` | 静音开关实际型号/触点、全部 VH 座针序、红灯硬件路径 | 连接器与服务口均为候选落图，不能视为线束冻结 |
| Head Carrier | 模组座、摄像头/隐私件和头部调试口最终针脚 | `H-IO-001` 通过；当前只允许 FFC/bulk/服务口候选 |

### 6.1 实体落图状态清单：未放项只放焊盘/符号，不得猜接

这一表是嘉立创操作后的实体落图状态。`FROZEN` 项可按给定值/封装入图；`GATE-DNP` 项必须有符号、0603/指定封装焊盘和功能位号，但不填猜测值、不连线到未冻结器件，也不计入可采购 BOM。标为 `A` 的项已经存在，禁止重复放置。

| 图页 | 功能位号 | 落图物 | 状态 | 放置与边界 |
|---|---|---|---|---|
| `01POWERUSB` | `R_EN0` | 0Ω、0603 | `FROZEN` | TPS56637 EN 默认使能配置位；仅在 `U6.EN` 邻近 |
| `01POWERUSB` | `R_PG5V`、`R_PG3V3` | 100kΩ、0603 各一 | `FROZEN` | 对应 U6/U7 开漏 PG 上拉；`R_PG3V3` 是当前下一件待放 |
| `01POWERUSB` | `R29` | 470Ω、1206、250mW | `FROZEN` | STUSB4500 `VBUS_VS_DISCH` 串联限流/泄放位 |
| `01POWERUSB` | `R33/R34` | 1.69kΩ / 1.10kΩ，0603，1% | `FROZEN` | TPS259470 Head/Motor 初始限流约 1.97A / 3.03A；实测后仍须 Gate 冻结 |
| `01POWERUSB` | `C48…C51` | 2.2nF、0603 | `FROZEN` | 两颗 eFuse 的 DVDT/ITIMER 首轮设定位；实测后可改值，不再按 DNP 处理 |
| `01POWERUSB` | `R39…R42` | 100kΩ/390kΩ，0603 | `FROZEN` | 两路 eFuse OVLO 分压，首轮上升阈值约 5.88V |
| `01POWERUSB` | `F1`、`R_SHIELD`、`C_SHIELD`、`R_SHIELD_0R` | BHFUSE `BSMD1812-200-16V`；其余为 EMI 位 | `A+GATE-DNP` | 输入保险已落图；Shield EMI 网络仍不得以普通跳线替代 |
| `01POWERUSB` | `D4` | `TPD2E2U06DRLR` | `BLOCKED-P0`（2026-08-13 已实放） | 原计划的 CC ESD 位；因耐压不符不得接线、不得作为 Rev A CC BOM，待替代方案批准后处置 |
| `02-MCU-DEBUG` | `R45`（`R_IOEXP_INT`） | 10kΩ、0603 | `A`（2026-08-13 已实放） | TCA9554 INT 上拉；尚未接线，且只能有这一颗 |
| `02-MCU-DEBUG` | `R_USB_DP/DM_DBG`、`D_UART_ESD` | 22Ω 串阻与低电容 ESD 占位 | `GATE-DNP` | 服务口保护，不替代 01 页 USB 主链路的两颗已放 22Ω |
| `03-AUDIO-IN` | `C_MIC1/2_LOCAL`、`C_MIC_A_ENTRY` | 100nF×2、1µF×1 | `GATE-DNP` | 仅在 `H-MIC-001` 确认模拟麦封装/供电脚后贴近麦克风落位 |
| `03/04-AUDIO` | `R_AEC_CFG`、`C_AEC_CFG`、`R_CODEC_PA`、`C_CODEC_PA` | 0603 调节/隔直焊盘 | `GATE-DNP` | Codec 模拟链/AEC 增益调整；不允许为消除悬空直接短接 |
| `05-HEAD-LINK` | `D_FFC_ESD`、`R_HEAD_CS_PU`、`R_HEAD_RST_PU`、`R_HEAD_READY_PD` | FFC ESD 阵列与 0603 上下拉位 | `GATE-DNP` | `H-FFC-001` 与 `H-IO-001` 未通过前只留位，不冻结方向/针序 |
| `06-MOTION-IO` | `D_MOTOR_P/T`、`R_SNUB_P/T`、`C_SNUB_P/T` | 电机 TVS、RC snubber 位 | `GATE-DNP` | 靠电机座；反电动势实测后选择具体料号与值 |
| `06-MOTION-IO` | `D_ENC_ESD_P/T`、`D_LIMIT_ESD_P/T` | 低电容 ESD 阵列位 | `GATE-DNP` | 靠对应连接器，等待线缆/编码器输出制式冻结 |
| `06-MOTION-IO` | `R_LIMIT_PU_P/T`、`C_LIMIT_P/T`、`U_LIMIT_SCHMITT` | 限位上拉、RC、施密特配置位 | `GATE-DNP` | 先完成 C3 绑带/常闭回路上电实测，禁止先接 GPIO8/9 |
| `07-CONNECTORS-TEST` | `Q_MUTE_SW`、`R_MUTE_SENSE`、`R_LED_MUTE` | 麦克风硬断开/状态检测/红灯限流位 | `GATE-DNP` | 静音开关的实际触点与 MICBIAS 方案未冻结前，只留独立硬件路径位 |
| `H0-HEAD-REVA` | `J_HEAD_MODULE`、`J_CAM`、`D_HEAD_EXT_ESD`、`R_HEAD_IO_CFG` | 模组座、摄像头座、外部 ESD、GPIO 配置位 | `GATE-DNP` | `H-IO-001` 完成前不可选符号或把 FFC 信号接到未知 HEAD-S3 引脚 |

完成这份表中所有符号落图，仍然只达到“可开始人工接线/复核”的前置条件；实际连线、ERC、PCB 转换、生产文件和采购各自需要后续 Gate。

## 7. 资料依据

- [TPS56637 datasheet](https://www.ti.com/lit/ds/symlink/tps56637.pdf)：RPA pinout、BOOT-SW 100nF、反馈与功率回路。
- [TPS62132 datasheet](https://www.ti.com/lit/ds/symlink/tps62132.pdf)：固定 3.3V 连接、FB/AGND/EP、SW/PVIN/PG。
- [STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf)：CC、VDD、PD 状态脚、`VBUS_EN_SNK` 与 VREG 去耦。
- [TPS25947 datasheet](https://www.ti.com/lit/ds/symlink/tps25947.pdf)：eFuse 的 EN/OVLO/ILM/DVDT/FLT/IN/OUT pin requirements。
- [硬件板级设计规范](10_hardware_board_design_spec.md)：本项目的分域、接口、GPIO、时序、Gate 与禁止项。
