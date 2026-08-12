# 小熙 Hushlight H0C Rev A 原理图人工接线交接单

> 版本：V0.1  
> 日期：2026-08-12  
> 状态：供人工连线；不代表 ERC 通过、可转 PCB、可打板或可采购  
> 适用工程：`Hushlight.eprj2` → `H0-BASE-REVA` / `H0-HEAD-REVA`

## 1. 结论与使用边界

当前嘉立创工程有 **46 个已保存对象**。`01POWERUSB` 的 PD 入口、主 Buck、3.3V Buck、音频 LDO、两路 eFuse、USB-C/ESD 和首轮主 Buck R/C/L 已放置；其他页主要仍是核心芯片或连接器骨架。

因此，**不能说“全部放置好了”**。本单把工作拆为三类：

| 标记 | 含义 | 执行规则 |
|---|---|---|
| `A` | 已放置且可按本单接线 | 按“源引脚 → 目标引脚/网络”连；每个网络标签改名后按 `Return` 提交 |
| `B` | 已批准但外围未放 | 先补齐本单指定的外围，再接线 |
| `GATE` | 器件、引脚或电气条件尚未冻结 | 只留框/测试位，不得猜测后接线 |

本单是人工在 EDA 中执行的接线说明，服从 [`10_hardware_board_design_spec.md`](10_hardware_board_design_spec.md)。发生冲突时，以 10 和器件原厂 datasheet 为准。本单不授权转 PCB、打板、采购或下单。

## 2. 每页布局：先按这个摆，再开始连

| 图页 | 从左到右 / 上到下布局 | 当前状态 |
|---|---|---|
| `00_SYSTEM` | 只放三域方框、跨页网络端口和版本/安全说明；不放功率环路 | `B`，用于总览，不承担细节连线 |
| `01POWERUSB` | 左：USB-C、ESD、STUSB4500、TVS；中：P-MOS、输入保护、TPS56637 与其输入/BOOT/电感/输出环；右上：TPS62132→`BASE_3V3`；右中：TPS7A2033→`AUDIO_3V3A`；最右：Head/Motor eFuse 与测试点 | `A` 主件和部分 R/C/L 已放；仍缺 PD/eFuse/次级电源外围 |
| `02-MCU-DEBUG` | 中：BASE-S3 模组；左：EN/BOOT/USB；右：UART、I2C、Head SPI、Motion UART；下：TCA9554、调试口、测试点 | `B`，仅 U1 骨架，不得先接未分配 GPIO |
| `03-AUDIO-IN` | 左：MIC1/MIC2 与模拟滤波；中：ES7210；右：I2S、AEC 参考和调试点；模拟电源从下方进入 | `B`，ES7210 已放；模拟麦、去耦、偏置、滤波未完成 |
| `04-AUDIO-OUT` | 左：ES8311；中：Codec→功放的调节/测试位；右：NS4150B、扬声器座；功放 bulk 在右下 | `B`，U3/U2 已放；外围未完成 |
| `05-HEAD-LINK` | 左：BASE-S3 侧串阻/ESD；中：30Pin FFC；右：头部端口与测试点；电源针放上，SPI/UART 放中，GND 回流针夹在信号间 | `B`，连接器型号、同面/异面和线束仍为 `H-FFC-001` Gate |
| `06-MOTION-IO` | 左：MOTION-C3、刷写/心跳/kill；中：DRV8833 与 VM bulk；右上：PAN 电机与编码器/限位；右下：TILT 电机与编码器/限位 | `B`，U8/U9 已放；电机、编码器、限位、栅极/输入保护未完成 |
| `07-CONNECTORS-TEST` | 左：EC11、锁定静音；中：红灯/TCA9554；右：Base/Motion/Head 服务调试口；下：按电源、USB、音频、运动分组的测试点 | `B`，当前只保留结构占位 |
| `H0-HEAD-REVA` | 左：AMOLED 计算模组座/供电；中：摄像头、隐私灯、快门检测；右：Base FFC、头部调试口；模组天线区域留空 | `GATE`，必须先完成 `H-IO-001`，不得猜测 34Pin 扩展 GPIO 或摄像头 DVP 引脚 |

### 2.1 页内连线规则

1. 每个跨页网使用同一网络标签，不跨页面画长线。建议名称：`VBUS_RAW`、`VBUS_PD`、`5V_SYS`、`BASE_3V3`、`AUDIO_3V3A`、`HEAD_5V`、`MOTOR_5V`、`GND`。
2. 网络标签必须落在**实际导线端点**。编辑名字后按 `Return`，再点击空白处并在右侧属性复核，不保留 `NET1`、`NET2` 等自动名。
3. `SW_5V`、`BOOT_5V`、`FB_5V` 只在 TPS56637 局部环路使用，不得跨页、不接测试排针。
4. GND 在原理图为同一 `GND` 网络；PCB 不切割主地平面。模拟隔离靠布局和受控回流实现。
5. 不在本单标为 `GATE` 的器件上“先随便接一下”。未冻结的摄像头、FFC 针位、MT6701 物理接口和模拟麦完整外围，必须等待 Gate。

## 3. `01POWERUSB`：人工逐针接线

按以下顺序执行：先入口与受控功率路径，再主 Buck、次级 Buck/LDO，最后两路 eFuse；每完成一个网络立即保存并复查网络名。

### 3.1 入口、PD 和受控功率路径

先补放 `B` 项：CC ESD 阵列、`STUSB4500` 的两颗 1µF 稳压去耦、I2C/开漏上拉、`VBUS_VS_DISCH` 串联限流电阻、输入保险/限流位、USB D+/D− 22Ω 串阻。下表中 `J_USB1.VBUS` 指 Type-C 连接器所有 VBUS 触点的同名汇合网，`J_USB1.GND` 同理。

| 序号 | 源引脚 | 目标引脚 / 网络 | 状态 | 规则 |
|---:|---|---|---|---|
| 1 | `J_USB1.CC1` | `U5.STUSB4500.CC1`（pin 2） | `B` | 不并 5.1kΩ Rd；CC ESD 靠连接器 |
| 2 | `J_USB1.CC2` | `U5.CC2`（pin 4） | `B` | 同上 |
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
| 15 | `U5.POWER_OK3`（pin 14） | `BASE-S3` 的待分配低压输入 + 3.3V 上拉 | `B` | 名称 `PD_12V_OK_N`；只作全性能准入，不直接驱动功率器件 |
| 16 | `U5.SCL`（pin 7） | `BASE-S3.GPIO18 / SYS_I2C_SCL` | `B` | 4.7kΩ 上拉到 `BASE_3V3` |
| 17 | `U5.SDA`（pin 8） | `BASE-S3.GPIO17 / SYS_I2C_SDA` | `B` | 4.7kΩ 上拉到 `BASE_3V3` |
| 18 | `U5.ALERT`（pin 19） | `TCA9554.P3 / PD_INT_N` + 3.3V 上拉 | `B` | 开漏；若不做诊断，仍保留测试点 |
| 19 | `U5.ADDR0`（pin 12）、`U5.ADDR1`（pin 13） | `GND` | `B` | 形成既定候选地址 `0x28` |
| 20 | `U5.GND`（pin 10）和 EP | `GND` | `B` | EP 完整接地铜 |
| 21 | `U5.VREG_1V2`（pin 21） | 1µF → `GND` | `B` | 仅去耦，不给外部负载 |
| 22 | `U5.VREG_2V7`（pin 23） | 1µF → `GND` | `B` | 仅去耦，不给外部负载 |
| 23 | `U5.VSYS`（pin 22） | `GND` | `B` | Rev A 无独立系统备用供电，不得悬空 |
| 24 | `J_USB1.D+` / `D−` | `D2.TPD2EUSB30A` 对应受保护通道 → 22Ω 串阻 → `BASE-S3.GPIO20/USB_DP`、`GPIO19/USB_DN` | `A+B` | 差分对同层、90Ω；D2 的 GND 脚最短到地 |

### 3.2 12V→5.1V 主 Buck：TPS56637

`TPS56637` 引脚号以 RPA-10 为准。`C1/C2/C3/C4/L1/R3/R4/C5…C8` 已放置；连线完成后，用局部网络标签而不是穿越整个页面的长线。

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
| 14 | `U6.EN`（pin 1） | `VBUS_PD` | `B` | 先以 0Ω/DNP 分压位接入；主 Buck 允许在 9V 和 12V 受控路径工作 |
| 15 | `U6.MODE`（pin 10） | 悬空（默认 FCCM） | `A` | 不放普通网络标签；预留 `0Ω DNP → GND` 改 Eco-mode |
| 16 | `U6.PG`（pin 4） | `5V_SYS_PG`，再经 100k 上拉到 `BASE_3V3` | `B` | 开漏输出；BASE-S3 读取启动状态 |
| 17 | `U6.NC`（pin 5） | 不连接 | `A` | 必须标非连接，不接 GND |

### 3.3 5V→BASE_3V3：TPS62132

先补放：`L2=2.2µH`、`C9=10µF/10V`、`C10=100nF/10V`、`C11=22µF/6.3V`、`C12=3.3nF/25V`、`R5=100k`。固定 3.3V 型的 `FB` 不使用分压。

| 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|
| `U7.AVIN`（pin 10）、`PVIN`（pins 11,12） | `5V_SYS` | C9/C10 正端同点、近端 |
| `C9.2`、`C10.2` | `GND` | 回 U7 PGND/EP 邻近 |
| `U7.SW`（pins 1,2,3） | `L2.1` | 仅局部 `SW_3V3` |
| `L2.2` | `BASE_3V3` | 输出节点 |
| `C11.1`、`U7.VOS`（pin 14）、`U7.FSW`（pin 7） | `BASE_3V3` | FSW 取 1.25MHz 目标，最终以 datasheet/EMI 实测冻结 |
| `C11.2` | `GND` | 输出电容回路最短 |
| `U7.FB`（pin 5） | `U7.AGND`（pin 6） | TPS62132 固定输出型要求 |
| `U7.DEF`（pin 8） | `GND` | 保持标称 3.3V，不要拉高到 +5% |
| `U7.SS/TR`（pin 9） | `C12.1`；`C12.2→GND` | 首轮软启动位 |
| `U7.EN`（pin 13） | `5V_SYS` | 先直连；如需由 `5V_SYS_PG` 延迟，再改为受控位 |
| `U7.PG`（pin 4） | `BASE_3V3_PG` + `R5.1`；`R5.2→BASE_3V3` | 开漏上拉 |
| `U7.AGND`（pin 6）、`PGND`（pins 15,16）、EP | `GND` | EP 必焊接地 |

### 3.4 5V→AUDIO_3V3A：TPS7A2033

先补放 `C13=2.2µF/10V`、`C14=2.2µF/6.3V`、`R6=100k`（可选 PG 上拉）。严格按 `TPS7A2033PDBVR` 的实际符号 pin name 落图；若 EDA 符号与 datasheet 不一致，停下并记录，不以猜测编号连线。

| 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|
| `U10.IN` | `5V_SYS` + `C13.1` | 音频电源入口 |
| `C13.2` | `GND` | 近端 |
| `U10.OUT` | `AUDIO_3V3A` + `C14.1` | 仅 ES7210、ES8311、麦克风模拟敏感域 |
| `C14.2`、`U10.GND` | `GND` | 不切割地平面 |
| `U10.EN` | `5V_SYS` 或受控 `AUDIO_EN` | 默认不悬空；爆音策略由 BASE 状态机控制 |

### 3.5 Head / Motor eFuse：TPS259470

U11 与 U12 使用相同 pinout；必须先补 `EN/UVLO`、`OVLO`、`ILM`、`DVDT` 的设定电阻/电容，不能悬空。初始限流 2.0A / 3.0A 仍是 `H-PWR-001` Gate，电阻值按当次 TI datasheet 曲线计算并记录，不能凭经验填值。

| 器件 | 源引脚 | 目标引脚 / 网络 | 规则 |
|---|---|---|---|
| U11 Head | `IN`（pin 5） | `5V_SYS` | eFuse 输入近端 10µF + 100nF |
| U11 Head | `OUT`（pin 6） | `HEAD_5V` → FFC pins 5–8 | FFC 两端另放 47–100µF + 1µF + 100nF |
| U11 Head | `EN/UVLO`（pin 1） | `HEAD_PWR_EN` + 默认下拉/分压 | BASE-S3 GPIO16 控制；不上电默认关闭 |
| U11 Head | `FLT`（pin 4） | `HEAD_OC_N` → TCA9554.P4 + 3.3V 上拉 | 开漏低有效 |
| U11 Head | `ILM`（pin 9） | `R_ILIM_HEAD → GND` | 目标 2.0A，值待 Gate |
| U11 Head | `DVDT`（pin 7） | `C_DVDT_HEAD → GND` | 软启动值待 Gate |
| U11 Head | `ITIMER`（pin 10） | `C_TIMER_HEAD → GND` 或按 TI 允许悬空 | 先保留焊盘 |
| U11 Head | `OVLO`（pin 2）、`GND`（pin 8） | OVLO 分压到 `5V_SYS`/GND；GND→GND | OVLO 不悬空 |
| U12 Motor | `IN`（pin 5） | `5V_SYS` | Motor 域独立输入去耦 |
| U12 Motor | `OUT`（pin 6） | `MOTOR_5V` → DRV8833 VM | U12 后先到 470µF + 10µF + 100nF bulk |
| U12 Motor | `EN/UVLO`（pin 1） | `MOTOR_PWR_EN` + 默认下拉/分压 | 默认关闭；仅限位/心跳正常后允许 |
| U12 Motor | `FLT`（pin 4） | `MOTOR_OC_N` → TCA9554.P5 + 3.3V 上拉 | 开漏低有效 |
| U12 Motor | `ILM`（pin 9） | `R_ILIM_MOTOR → GND` | 目标 3.0A，值待 Gate |
| U12 Motor | `DVDT`（pin 7）、`ITIMER`（pin 10）、`OVLO`（pin 2）、`GND`（pin 8） | 同 U11 相应规则 | `OVLO`、`ILM` 不得浮空 |

## 4. 其余页：现在只接批准的核心网络

本节只列当前可由已批准 GPIO/接口表直接推出的连接；凡需完整器件外围或实物针脚证据的部分均保留为补放或 Gate。

### 4.1 `02-MCU-DEBUG`：BASE-S3

`U1=ESP32-S3-WROOM-1-N16R8` 的 GPIO 只能按 10 第 8.1 节使用。人工先补齐模组的 3.3V 入口、EN RC、BOOT/RESET、USB/UART 和去耦；天线禁布区不画任何连接器/铜皮含义的占位。

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

### 4.2 `03-AUDIO-IN`：ES7210 与双模拟 MEMS

ES7210 的模拟输入模式、MICBIAS、AC 耦合/偏置和 AEC 参考输入必须按 Korvo-2 V3.1 + ES7210 datasheet 逐脚核对后再连。当前不写伪精确的 MIC 脚号。

| 可立即建立的网络 | 连接 | 条件 |
|---|---|---|
| `I2S_MCLK/BCLK/LRCK` | U1 GPIO4/5/6 → U4 对应数字时钟脚 | U4 符号与 datasheet pin name 一致后 |
| `ADC_SDOUT` | U4 数字数据输出 → U1 GPIO7 | 方向单向 |
| `AUDIO_3V3A` / `GND` | U4 模拟电源、双麦供电和本地去耦 | MIC 料号冻结前先只留去耦焊盘 |
| `AEC_REF` | ES8311 DAC 模拟输出、功放前分支 → ES7210 参考输入 | 禁止从 NS4150B 喇叭输出取样 |

### 4.3 `04-AUDIO-OUT`：ES8311、NS4150B 与扬声器

| 源 | 目标 | 规则 |
|---|---|---|
| U1 `I2S_MCLK/BCLK/LRCK`、`DAC_DSDIN` | U3 ES8311 相应 I2S pins | 共享时钟；先核对符号 pin name |
| U3 DAC 模拟输出 | U2 NS4150B 输入，经 0Ω/RC/隔直 DNP 位与 TP11 | AEC 参考在此处分支 |
| U1 GPIO48 `PA_ENABLE` | U2 使能脚 | 10k 下拉，默认关功放 |
| U2 BTL 输出 | `J_SPK1.SP+ / SP−` | 两根都不接地；靠连接器、成对走线 |
| `5V_SYS` | U2 功放电源入口 + `220µF + 10µF + 100nF` 至 GND | 功放 bulk 靠 U2；不经 AUDIO_3V3A |

### 4.4 `05-HEAD-LINK`：30Pin FFC

完全按 10 第 7.2 节 Pin 1–30 表连。底座侧 `HEAD_PWR_EN` 只接 U11 的控制网络；FF C pin 18 只传逻辑状态，不承载 eFuse 电流。摄像头 DVP 和 AMOLED QSPI 不经过这条 FFC。

### 4.5 `06-MOTION-IO`：MOTION-C3 与 DRV8833

| 源 | 目标 | 状态/规则 |
|---|---|---|
| U8 GPIO0/1 | U9 DRV8833 `AIN1/AIN2` | `A` 核心网络；0/1 均预留串阻 |
| U8 GPIO2/3 | U9 `BIN1/BIN2` | `A`；GPIO2 是绑带脚，电阻网络复核后才允许接 |
| U9 `AOUT1/AOUT2` | `J_MOTOR_P.1/.2` | `B`，连接器防反插 |
| U9 `BOUT1/BOUT2` | `J_MOTOR_T.1/.2` | `B` |
| U12 `MOTOR_5V` | U9 `VM` + 近端 `10µF + 100nF` + Motor bulk | `B`，不从 BASE_3V3 取电 |
| U8 GPIO21 | U9 `nSLEEP` | `A`；10k 下拉，硬件默认关电机 |
| U9 `nFAULT` | U8 GPIO10 + 3.3V 上拉 | `B`，开漏/低有效按 datasheet |
| U8 GPIO4/5、6/7 | PAN/TILT 编码器 `A/B` | `GATE`，MT6701 实测输出制式后冻结 |
| U8 GPIO8/9 | PAN/TILT 常闭限位回路 | `GATE`，绑带电平、断线安全和 RC/施密特先验证 |
| U1 GPIO21/38 | U8 GPIO18/19 | `A`，Motion UART TX↔RX；共地 |
| U1 GPIO47 | U8 安全停机/驱动禁止逻辑 | `B`，不依赖串口超时单独保安全 |

### 4.6 `07-CONNECTORS-TEST` 与 Head Carrier

- EC11：`A/B → U1 GPIO1/2`，`SW → TCA9554.P0`，共同端接 GND；A/B 以 RC/软件消抖二选一，不能双重造成迟滞。
- 静音锁定开关：一组触点硬件关闭麦克风有效供电/ES7210 MICBIAS，另一组触点形成 `MUTE_SENSE → U1 GPIO39`；红灯由独立硬件路径点亮，TCA9554.P1 只读/辅助显示。
- Head Carrier：只在完成 `H-IO-001` 后，根据 Waveshare 34Pin 原理图把 `HEAD_SPI_*`、`HEAD_UART_*`、`HEAD_READY`、`SHUTTER_CLOSED_N` 接到实际扩展脚。当前禁止把摄像头直接并到未知 GPIO。

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
| `01POWERUSB` | STUSB4500 的 CC ESD、VREG 1µF×2、I2C/开漏上拉、放电限流、输入保险、USB 22Ω；TPS62132/TPS7A20/eFuse 全部设定件 | 没有这些项不得跑 ERC 并宣称电源完整 |
| `02-MCU-DEBUG` | EN/BOOT/RESET、电源入口 bulk/去耦、USB/UART 服务口、TCA9554 | 绑带和 PSRAM 占脚通过复核 |
| `03/04-AUDIO` | 两只同型号模拟 MEMS、ES7210/ES8311/NS4150B 的 datasheet 级供电/模拟外围 | `H-MIC-001` 与音频 pin mapping 通过 |
| `05-HEAD-LINK` | 30Pin FFC 具体料号、ESD、串阻、头部 bulk | `H-FFC-001` 通过 |
| `06-MOTION-IO` | 电机/编码器/限位连接器、VM bulk、输入保护、编码器与限位滤波 | `H-MOT-001`、`H-ENC-001` 通过 |
| Head Carrier | 模组座、摄像头/隐私件和头部调试口 | `H-IO-001` 通过 |

## 7. 资料依据

- [TPS56637 datasheet](https://www.ti.com/lit/ds/symlink/tps56637.pdf)：RPA pinout、BOOT-SW 100nF、反馈与功率回路。
- [TPS62132 datasheet](https://www.ti.com/lit/ds/symlink/tps62132.pdf)：固定 3.3V 连接、FB/AGND/EP、SW/PVIN/PG。
- [STUSB4500 datasheet](https://www.st.com/resource/en/datasheet/stusb4500.pdf)：CC、VDD、PD 状态脚、`VBUS_EN_SNK` 与 VREG 去耦。
- [TPS25947 datasheet](https://www.ti.com/lit/ds/symlink/tps25947.pdf)：eFuse 的 EN/OVLO/ILM/DVDT/FLT/IN/OUT pin requirements。
- [硬件板级设计规范](10_hardware_board_design_spec.md)：本项目的分域、接口、GPIO、时序、Gate 与禁止项。
