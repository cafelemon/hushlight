# 小熙 Hushlight H0C Rev A 硬件板级设计规范

> 文档版本：V0.1
> 更新日期：2026-08-12
> 状态：板级架构已批准；原理图实施开始，样件验证与采购未开始
> 设计优先级：首版效果与稳定性优先于成本，成本优化后置
> 权威范围：H0C 自研板的器件选型、电源树、接口、GPIO、保护、去耦、层叠、布局布线及设计 Gate
> 上游依据：[08_hardware_prototype_plan.md](08_hardware_prototype_plan.md)
> 变更关系：本文取代 [09_jlceda_placement_guide.md](09_jlceda_placement_guide.md) 中的单主控、5V/2A、2.4 英寸 320×240 屏及待定数字麦假设；09 仅保留为首次人工放置记录

## 1. 结论

H0C Rev A 不采用“单颗 ESP32-S3 同时承担语音、联网、高清动画、摄像头与双轴闭环”的方案。首板拆成三个独立实时域：

1. **底座主控 `BASE-S3`**：负责双麦/AEC、播放、唤醒、联网、云端会话、隐私状态、物理控件与整机编排。
2. **头部视觉主控 `HEAD-S3`**：负责 600×450 AMOLED、触摸、摄像头采集、本地人脸位置和角色动画。
3. **运动控制器 `MOTION-C3`**：负责双轴电机 PWM、角度反馈、限位、轨迹执行、失控停机和看门狗。

该拆分的目标不是堆算力，而是隔离不同实时负载：屏幕刷帧或视觉峰值不得中断语音；Wi-Fi/云请求不得造成运动抖动；运动控制器故障不得破坏静音与基础聊天。ESP32-P4 作为 Rev B 的视觉升级候选，不进入 Rev A 首板。

```text
USB-C PD 12V/3A
      │
      ├── 5V_SYS ── BASE-S3 ── ES7210 ── 双路模拟 MEMS
      │              │  └────── ES8311 → NS4150B → 4Ω/3W
      │              ├── SPI/UART/控制 ── 30Pin FFC ── HEAD-S3
      │              └── UART+CRC ─────── MOTION-C3
      │
      ├── 5V_HEAD（可关断）── AMOLED + Touch + Camera
      └── 5V_MOTOR（限流/可关断）── DRV8833 ── Pan/Tilt 电机
                                           └── 双路绝对角度反馈
```

## 2. Rev A 设计目标与边界

### 2.1 必须达到

- 角色屏达到 600×450、核心动画不低于 20 fps，触摸反馈 P95 小于 150 ms。
- 摄像头只在唤醒/对话期间工作，只输出目标坐标、置信度与时间戳；不把原始帧传到底座、云端、Web 或 PC Bridge。
- 双轴运动平滑、有闭环角度、有软硬限位；`MOTION-C3` 失联时硬件进入安全停机。
- 基础语音链路在显示刷新、摄像头工作和电机动作时不掉帧、不回声自激、不 brownout。
- 硬件静音切断麦克风有效采集通路，且状态可由底座主控检测；不能只做软件变量。
- 底座、头部和运动固件可独立刷写、回滚和诊断；版本由底座统一报告。

### 2.2 本轮不做

- 不以千台 BOM 150 元约束首板选型；Rev A 先证明体验，再形成 Rev B 降本表。
- 不自研裸 AMOLED 玻璃的全部电源与 FPC 适配；首板使用成熟显示计算模组或等效已验证方案。
- 不在 ESP32 上运行通用大模型；端侧只做唤醒、音频前处理、角色渲染和轻量视觉。
- 不做电池、MIPI 摄像头、4K 视频、原始视频上传、待机跟随或持续巡视。
- 不冻结消费版 PCB 尺寸、ID、量产器件替代和认证方案。

## 3. 版本和变更控制

所有原理图、PCB 和样机必须同时记录：

```text
bom_rev
base_hw_rev
head_hw_rev
motion_hw_rev
enclosure_rev
base_fw_tag
head_fw_tag
motion_fw_tag
```

状态定义：

| 状态 | 含义 |
|---|---|
| `FROZEN-A` | 可进入 Rev A 原理图；改动必须更新本文与决策记录 |
| `CANDIDATE` | 原理图可保留兼容位或接口，但样件验证前不得下单 PCB |
| `MODULE-A` | Rev A 使用成熟模组，后续允许集成降本 |
| `DNP` | 首板不装，只保留焊盘/测试能力 |
| `REJECTED-A` | 已评估但不进入 Rev A |

任何 `FROZEN-A` 器件替换必须同时复核：供电、逻辑电平、GPIO、时钟、封装、热设计、软件驱动和嘉立创可采购性。网店标题、第三方符号和旧版清单不能替代 datasheet。

## 4. 功能分区与故障隔离

| 域 | 处理器 | 主要职责 | 故障后的最低行为 |
|---|---|---|---|
| 底座 | ESP32-S3-WROOM-1-N16R8 | 音频、Wi-Fi、会话、状态、静音、整机编排 | 头部或运动失效时仍可语音和明确报错 |
| 头部 | ESP32-S3R8 + 16MB Flash 的 2.41 英寸 AMOLED 模组 | 动画、触摸、摄像头、端侧目标坐标 | 摄像头失败仍显示角色；通信失败进入本地离线表情 |
| 运动 | ESP32-C3-MINI-1-N4 | 1 kHz 级控制环、双轴反馈、限位、安全停机 | 上位命令超时或 MCU 复位时 `nSLEEP=0`，电机高阻 |

### 4.1 为什么不是单颗 ESP32-S3

- 音频 DMA、Wi-Fi、显示刷新和 DVP 摄像头会同时争用内存带宽、DMA、GPIO 和实时调度余量。
- 视觉与动画升级会持续挤压音频稳定性，造成难以定位的跨域回归。
- 双轴控制需要固定周期和独立看门狗，不能依赖正在处理网络或屏幕任务的同一调度域。
- 三域架构允许先用成熟头部模组证明效果，量产阶段再决定是否合并处理器。

### 4.2 为什么 Rev A 不上 ESP32-P4

ESP32-P4 的 MIPI CSI/DSI、ISP、PPA、JPEG/H.264 和更高算力适合未来更复杂视觉，但当前官方 datasheet 仍为 pre-release，QFN104、外部存储与多电源/高速接口显著增加首板风险。Rev A 的目标是尽快得到稳定且高表现力的研发设备，因此保留 `P4_HEAD` 作为 Rev B 研究项，不进入 Rev A BOM。

## 5. 器件选型基线

### 5.1 核心器件

| 子系统 | Rev A 选择 | 状态 | 选型理由与约束 |
|---|---|---|---|
| 底座主控 | ESP32-S3-WROOM-1-N16R8 | `FROZEN-A` | 16MB Flash、8MB Octal PSRAM；有成熟 ESP-SR、ESP-ADF 与 OTA 生态 |
| 头部显示计算 | Waveshare ESP32-S3-Touch-AMOLED-2.41 标准版或电气等效模组 | `MODULE-A` | 2.41 英寸、600×450、QSPI RM690B0、FT6336、8MB PSRAM、16MB Flash；先证明角色表现 |
| 头部载板 | 自研 4 层 carrier，连接显示模组、摄像头、隐私件与底座 FFC | `FROZEN-A` | 保持头部为自研机械/电气系统，同时隔离裸屏首板风险 |
| 摄像头 | OV3660 DVP 模组；OV5640 留兼容性评估 | `CANDIDATE` | 官方/成熟 ESP32 摄像头驱动路径；只跑低分辨率本地目标定位 |
| 运动 MCU | ESP32-C3-MINI-1-N4 | `FROZEN-A` | 15 GPIO、LEDC、TWAI/UART、看门狗；不启用 Wi-Fi/BLE，专做闭环控制 |
| 双电机驱动 | DRV8833PWP | `FROZEN-A` | 2.7–10.8V、双 H 桥、限流、过流/过温/欠压保护、`nFAULT`/`nSLEEP` |
| 角度反馈 | 2 × MT6701，优先 ABZ 增量输出 + 上电绝对角校准；每轴 1 颗 | `CANDIDATE` | 无接触、分辨率高；必须先验证磁铁偏心、气隙、电机磁场与零位重复性 |
| 原点/硬限位 | 每轴 1 个独立限位开关或霍尔开关 | `FROZEN-A` | 不以磁编码器替代机械安全边界；采用常闭回路优先 |
| 音频 ADC | ES7210 | `FROZEN-A` | 四通道 ADC、I2S/TDM、MICBIAS；H0 只用两路同型号模拟 MEMS |
| 音频 DAC/Codec | ES8311 | `FROZEN-A` | 单路 ADC/DAC、I2S；作为播放 DAC 和 AEC 参考源 |
| 功放 | NS4150B | `FROZEN-A` | 延续 Korvo-2 已验证的 3W 级链路；首板保留散热与 EMI 调整位 |
| 模拟麦克风 | 2 × MSM381A3729H9BPC 或经灵敏度/封装等效验证的同批模拟 MEMS | `CANDIDATE` | Korvo-2 V3.1 参考使用模拟 MEMS；两只必须同型号、同批次、同声学结构 |
| GPIO 扩展 | TCA9554PWR，I2C 地址由硬件脚固定 | `FROZEN-A` | 承接旋钮/LED/低速控制，避免占用实时接口；不用旧清单的随意 U 位号 |

### 5.2 电源与保护器件

| 功能 | Rev A 选择 | 状态 | 备注 |
|---|---|---|---|
| USB-PD Sink | STUSB4500QTR | `FROZEN-A` | NVM 配置 12V 首选、9V 兼容、5V 故障诊断；无 MCU 也可协商 |
| 主降压 12V→5V | TPS56637RPAR，目标 5.1V/6A | `FROZEN-A` | 4.5–28V 输入、6A；电感与补偿/输出电容按 TI 推荐值计算并仿真/台架验证 |
| 底座 5V→3V3 | TPS62132RGTR，固定 3.3V/3A | `FROZEN-A` | 给 BASE-S3 与数字域，留 Wi-Fi 峰值余量；`TPS62133` 是固定 5.0V 型号，禁止混用 |
| 低噪声音频 3V3 | TPS7A2033PDBVR | `FROZEN-A` | 固定 3.3V、300mA、低噪声、高 PSRR；仅供音频模拟/麦克风敏感域；嘉立创 `C2862740` |
| Head 5V 开关 | TPS259470ARPWR | `FROZEN-A` | 2.7–23V、5.5A、真反向阻断；`HEAD_PWR_EN`、`HEAD_OC_N` 必须可观测；首版 `ILIM=2.0A`，台架后校正 |
| Motor 5V 开关 | TPS259470ARPWR | `FROZEN-A` | 与逻辑/音频分支分开，故障时可独立关断；首版 `ILIM=3.0A`，堵转测试后冻结；嘉立创 `C3662799` |
| USB2 ESD | TPD2EUSB30A 或等效低电容双路器件 | `FROZEN-A` | 靠近 Type-C D+/D− 入口 |
| Type-C CC short-to-VBUS | `STUSB4500QTR` 内置 CC 高压保护；不另加 D4 | `FROZEN-A` | CC1/CC2 直接进入 U5；原 `TPD2E2U06DRLR` 已从 EDA 删除，不能代替 CC 保护。U5 对 CC 提供 22V short-to-VBUS 保护；系统级 IEC ESD 表现作为 P1 台架验证项，不在本轮叠加另一颗 CC 保护 IC |
| USB-PD 受控功率路径 | `Q_PD1=AONR21321`（AOS，嘉立创 `C541711`） | `FROZEN-A` | 30V P-MOS，`RDS(on)` 最大 29.5mΩ @ −4.5V、额定 −24A；引脚 `1–3=S`、`4=G`、`5–8=D`。由 STUSB4500 `VBUS_EN_SNK` 的高压开漏直接驱动，保留 ST 参考方案的门极外围 |
| 入口 TVS | `D_VBUS_TVS=SMBJ15A`（Littelfuse，嘉立创 `C83846`） | `FROZEN-A` | 单向 SMB/DO-214AA；`VRWM=15V`、`VBR=16.7V`、`VC=24.4V @ 24.6A`，低于 TPS56637 28V 绝对最大额定值；阴极接 VBUS、阳极接 GND |

### 5.3 明确拒绝或后置

| 方案 | 状态 | 原因 |
|---|---|---|
| 单颗 ESP32-S3 承担全部整机功能 | `REJECTED-A` | 实时域耦合、GPIO/DMA/内存带宽紧张、回归定位困难 |
| ESP32-P4 头部主控 | `REJECTED-A` | 首板复杂度与资料成熟度风险高；Rev B 再评估 |
| 2.4 英寸 320×240 LCD 作为自研目标屏 | `REJECTED-A` | 参考联调可用，但不满足效果优先的角色表现目标 |
| MSM261DHP006 直接接 ES7210 | `REJECTED-A` | 该器件为数字麦，ES7210 输入为模拟路径，电气架构不兼容 |
| 软件静音 | `REJECTED-A` | 不构成可信隐私边界 |
| 智能舵机/Dynamixel 直接作为消费版方案 | `REJECTED-A` | 体积、噪声、供电和成本不匹配；仅可做算法台架对照 |

## 6. 电源树与功耗预算

### 6.1 输入规格

- 正式 Rev A 电源：USB-C PD 适配器，**12V/3A（36W）**。
- STUSB4500 PDO：`PDO1=5V`、`PDO2=9V`、`PDO3=12V`。`POWER_OK3` 是整机的全性能使能条件：仅 12V 合同成功后允许全亮屏 + 摄像头 + 双电机同时工作；9V 合同只能进入受限诊断模式。
- `POWER_ONLY_ABOVE_5V=1`：`VBUS_EN_SNK` 仅在 PDO2/PDO3 的显式合同建立后拉低，驱动 `Q_PD1` 导通；因此它不是“仅 12V”判据。`POWER_OK3` 必须进入 BASE 的电源状态/功耗管理；`5V` 附着、掉线、PD 协商失败和 20V 非请求 PDO 均不得让主 Buck 输入上电。
- 入口执行链固定为 `J_USB1 VBUS → D_VBUS_TVS → Q_PD1 (P-MOS) → VBUS_PD → 输入限流/主 Buck`；`STUSB4500` 的 VBUS 检测/供电脚留在 `Q_PD1` 前侧，不能接到受控输出侧。
- `Q_PD1` 门极最小外围：`R_GS=100kΩ`（Gate-Source 默认关断）、`R_GATE=100Ω`（`VBUS_EN_SNK` 串联）、`D_GS=15V` 齐纳钳位占位；后级总输入电容按 ST 参考和 TPS56637 启动波形复核，不能仅靠 P-MOS 导通瞬态假定安全。
- 5V/3A 非 PD 仅作为受限诊断模式：禁用电机、限制屏幕亮度和扬声器音量；不得悄悄进入全功能状态。
- USB-C 数据使用同一接口连接 BASE-S3 的 USB2 D+/D−；PD 协商与 USB2 数据共存。

### 6.1.1 首轮主电源外围（原理图实施值，待台架冻结）

以下数值用于把已批准的电源树落实为可审查原理图，来自 TI 的典型应用电路或由其反馈公式推导；它们不是采购冻结值。实际下单前必须同时核对封装、直流偏压后的有效电容、饱和电流、温升、启动浪涌和 ERC。

| 电路 | 首轮外围/数值 | 依据与待验证项 |
|---|---|---|
| `TPS56637`：`VBUS_PD → 5V_SYS` | `CIN1/CIN2=10µF/25V X7R`、`CIN_HF=100nF/50V X7R`、`CBOOT=100nF/16V X7R`、`L_SYS=3.3µH`（首轮候选：Coilcraft `XAL5030-332MEC` / 嘉立创 `C5342047`）、`COUT1…4=22µF/10V X7R`（候选：Taiyo Yuden、1206、嘉立创 `C524990`）、`RFB_H=75.0kΩ 1%`、`RFB_L=10.0kΩ 1%` | 采用 TI 8–28V→5V/6A Figure 17 的电容、电感和启动基线；反馈式 `VOUT=0.6×(1+RFB_H/RFB_L)` 推导为约 `5.10V`。候选电感为 3.3µH、典型 `Isat=8.7A`、`Irms=5.9A`（40°C 升温）：饱和裕量可用，但 6A 连续满载温升必须实测，未通过不得冻结。输出电容的有效值、纹波和 UVLO/PG 细节也必须在 5.1V 直流偏压、输入浪涌和 6A 负载测试后确认。 |
| `TPS62132`：`5V_SYS → BASE_3V3` | `L_3V3=2.2µH`、`CIN=10µF/10V X7R`、`COUT=22µF/6.3V X7R`、`CFF=3.3nF/25V`、`RPG=100kΩ`、`CIN_HF=100nF/10V X7R` | 采用 TI 3.3V 固定输出典型应用值；布局须让输入回路、SW 电感回路和输出回路最小化。 |
| `TPS7A2033`：`5V_SYS → AUDIO_3V3A` | `CIN=2.2µF/10V X7R`、`COUT=2.2µF/6.3V X7R`；每个音频 IC 再按自身 datasheet 本地去耦 | TI 要求输入、输出各至少 1µF 才保证稳定；2.2µF 是首轮余量而非替代 Codec/MIC 的本地电容。 |

- `TPS56637` 的输入去耦、`CBOOT` 和功率回路只能布在器件/电感近端；不得通过长窄线或跨音频地岛返回。主 Buck 的 SW 节点面积最小，禁止让其从 Type-C CC、音频、MICBIAS、晶振或天线下方/旁边穿过。
- 在 12V PD 合同建立、P-MOS 导通的最坏条件下，必须采集 `VBUS_PD`、`5V_SYS`、`BASE_3V3` 的启动波形；若入口快速熔断器与输入总电容的浪涌配合不成立，应改用经核对的慢断/可恢复方案或在受控路径加入限浪涌，不得仅凭额定电流放行。

### 6.2 功耗预算（首板设计值，不是实测值）

| 5V 分支 | 连续预算 | 峰值预算 | 说明 |
|---|---:|---:|---|
| `BASE_5V/3V3` | 0.6A | 1.0A | BASE-S3、I/O、调试 |
| `AUDIO_5V/3V3A` | 0.7A | 1.2A | Codec、双麦、3W 功放；按满幅播放估算 |
| `HEAD_5V` | 0.8A | 1.5A | AMOLED、HEAD-S3、触摸、摄像头；以样件实测修订 |
| `MOTOR_5V` | 0.8A | 2.5A | 两轴运行/启动与短时堵转；限流必须低于供电与驱动能力 |
| 余量 | 0.4A | 0.8A | 瞬态、线损、USB 外设与设计余量 |
| 合计 | 3.3A | 7.0A 非同时 | 主 5V 设计 6A；固件禁止所有峰值同时出现 |

峰值大于 6A 不是允许过载，而是要求做负载仲裁：电机启动时降低扬声器瞬态和屏幕峰值；功放大信号期间减少动作加速度。首板必须用示波器和电子负载验证 5V 最低点、纹波与 PD 重新协商行为。

### 6.3 电源时序

1. PD 合同成功，`PD_OK=1` 后开启 12V→5V 主 Buck。
2. `5V_SYS_PG=1` 后开启 `BASE_3V3`；BASE-S3 完成自检。
3. BASE-S3 拉高 `HEAD_PWR_EN`，等待 `HEAD_READY`，超时则关闭并报告故障。
4. `MOTOR_5V` 默认关闭；MOTION-C3 自检、限位输入有效且底座授权后才开启。
5. `DRV8833_nSLEEP` 必须有硬件下拉；MOTION-C3 未启动、失联或看门狗复位时电机保持关闭。
6. 物理静音立即关闭 `MIC_3V3A_SW` 或 ES7210/MICBIAS 有效硬件通路，并由独立红灯显示；解除后仍需再次主动唤醒。

## 7. 板卡与接口定义

### 7.1 板卡划分

| 板卡 | 嘉立创工程 | 内容 |
|---|---|---|
| `H0-BASE-REVA` | 现有 Base 工程 | PD、电源、BASE-S3、音频、MOTION-C3、DRV8833、控件、调试与 Head FFC |
| `H0-HEAD-CARRIER-REVA` | 现有 Head 工程需改名/落实 | AMOLED 计算模组插座、摄像头、隐私灯/遮挡检测、Head FFC 与测试点 |
| `H0-ENCODER-PAN/TILT-REVA` | 可复用同一小板 | MT6701、去耦、连接器、安装孔与磁铁对位标记 |

### 7.2 底座到头部 30Pin FFC

FFC 使用 0.5mm 间距、翻盖锁紧、额定电流满足多针并联后的头部峰值。头部有本地算力，因此 FFC **不传摄像头 DVP 或显示 QSPI**，只传电源、控制和低速数据。

| Pin | 信号 | 方向（以底座为准） | 规则 |
|---:|---|---|---|
| 1–4 | `GND` | — | 四针并联，首尾均安排回流 |
| 5–8 | `HEAD_5V` | 输出 | 四针并联；两端各放 bulk cap，核对连接器单针额定电流 |
| 9 | `HEAD_SPI_SCLK` | 输出 | 22–33Ω 源端串阻占位 |
| 10 | `GND` | — | SPI 时钟回流 |
| 11 | `HEAD_SPI_MOSI` | 输出 | 命令/资源块 |
| 12 | `HEAD_SPI_MISO` | 输入 | 状态/坐标/诊断 |
| 13 | `HEAD_SPI_CS_N` | 输出 | 默认上拉 |
| 14 | `GND` | — | 数据信号回流 |
| 15 | `HEAD_IRQ_N` | 输入 | 头部事件，开漏优先 |
| 16 | `HEAD_READY` | 输入 | 头部启动与健康状态 |
| 17 | `HEAD_RESET_N` | 输出 | 默认上拉，底座可复位头部 |
| 18 | `HEAD_PWR_EN` | 输出 | 控制底座侧 Head eFuse；不直接跨 FFC 驱动负载 |
| 19 | `HEAD_UART_TX` | 输出 | 115200 调试/恢复通道 |
| 20 | `HEAD_UART_RX` | 输入 | 115200 调试/恢复通道 |
| 21 | `CAM_ACTIVE_LED_SENSE` | 输入 | 硬件工作灯回读 |
| 22 | `SHUTTER_CLOSED_N` | 输入 | 物理遮挡检测，默认安全态 |
| 23 | `HEAD_TEMP_ALERT_N` | 输入 | DNP 兼容位 |
| 24 | `HEAD_BOOT_N` | 输出 | 仅服务模式使用，默认上拉 |
| 25 | `SPARE_DIFF_P` | 双向/保留 | 与 26 成对，Rev A DNP；为后续高速链路预留 |
| 26 | `SPARE_DIFF_N` | 双向/保留 | 不可在 Rev A 当普通杂线随意占用 |
| 27 | `SPARE_GPIO0` | 双向/保留 | 串阻/DNP |
| 28 | `SPARE_GPIO1` | 双向/保留 | 串阻/DNP |
| 29–30 | `GND` | — | 尾部回流与屏蔽 |

通信协议：SPI Mode 0，首板 10MHz，帧含 `magic/version/type/length/seq/payload/crc32`；每个请求有超时与序号，禁止裸结构体跨固件版本传输。头部只返回目标坐标和事件，不返回视频帧。

### 7.3 底座到运动控制器

Rev A 使用板内 3.3V UART，1Mbps，CRC32 帧，另设硬件 `MOTION_HEARTBEAT` 和 `MOTION_KILL_N`。板内短距离暂不引入 CAN 收发器；PCB 预留 TWAI TX/RX 测试焊盘，若运动板未来分体再升级为带收发器的 TWAI。

命令只允许：`HOME`、`MOVE_ABS`、`TRACK_TARGET`、`GESTURE`、`STOP`、`SET_LIMITS`、`GET_STATUS`。超过 100ms 未收到有效心跳，MOTION-C3 清空轨迹并拉低 `nSLEEP`；底座还可通过 `MOTION_KILL_N` 直接硬件禁止驱动。

### 7.4 外部与服务接口

| 接口 | 定义 | 约束 |
|---|---|---|
| `J_USB1` | USB-C PD + USB2 Device | CC、VBUS、D+/D−、Shield 均按保护规则处理 |
| `J_SPK1` | 2Pin 4Ω/3W 扬声器 | 锁扣连接器；差分输出不可任一端接地 |
| `J_MIC_DBG` | 两路模拟麦调试座 | DNP；只允许短线台架，不进入最终结构 |
| `J_MOTOR_P/T` | 两路 2Pin 电机 | 与编码器线分开，连接器防反插 |
| `J_ENC_P/T` | 每轴 VCC/GND/A/B/Z/诊断 | 屏蔽/双绞按样机噪声决定；靠传感器端去耦 |
| `J_LIMIT_P/T` | 每轴常闭限位回路 | 断线等价触发，不得仅靠软件软限位 |
| `J_BASE_DBG` | 3V3/GND/UART0/EN/BOOT | 服务盖板内，不对用户暴露 |
| `J_MOTION_DBG` | 3V3/GND/UART/EN/BOOT | 可独立刷写 C3 |
| `J_HEAD_DBG` | 头部载板 UART/USB/BOOT | 头部拆下后可独立供电调试，避免通过 FFC 回灌 |

## 8. GPIO 分配

GPIO 表是 Rev A 原理图权威。任何变更先更新本节，再改图。

### 8.1 BASE-S3：ESP32-S3-WROOM-1-N16R8

| GPIO | 信号 | 方向 | 备注 |
|---:|---|---|---|
| 0 | `BOOT_N` | 输入 | 启动绑带脚，只接按键/上拉 |
| 1 | `ENC_A` | 输入 | EC11，经 RC/施密特或软件消抖 |
| 2 | `ENC_B` | 输入 | EC11 |
| 3 | `NC_STRAP` | — | 绑带脚，不使用 |
| 4 | `I2S_MCLK` | 输出 | ES7210/ES8311 |
| 5 | `I2S_BCLK` | 输出 | 共享音频时钟 |
| 6 | `I2S_LRCK` | 输出 | 共享音频帧时钟 |
| 7 | `ADC_SDOUT` | 输入 | ES7210 → S3 |
| 8 | `DAC_DSDIN` | 输出 | S3 → ES8311 |
| 9 | `HEAD_SPI_SCLK` | 输出 | 源端串阻 |
| 10 | `HEAD_SPI_MOSI` | 输出 | 源端串阻 |
| 11 | `HEAD_SPI_MISO` | 输入 | Head 端源串阻 |
| 12 | `HEAD_SPI_CS_N` | 输出 | 上拉 |
| 13 | `HEAD_IRQ_N` | 输入 | 上拉/中断 |
| 14 | `HEAD_READY` | 输入 | 下拉，防悬空误判 |
| 15 | `HEAD_RESET_N` | 输出 | 上拉 |
| 16 | `HEAD_PWR_EN` | 输出 | 控制 Head eFuse，默认关闭 |
| 17 | `SYS_I2C_SDA` | 双向 | ES7210、ES8311、TCA9554、PD 诊断；地址表见 8.4 |
| 18 | `SYS_I2C_SCL` | 输出 | 4.7kΩ 起始值，按总线电容实测 |
| 19 | `USB_DN` | 双向 | 原生 USB，90Ω 差分 |
| 20 | `USB_DP` | 双向 | 原生 USB，90Ω 差分 |
| 21 | `MOTION_UART_TX` | 输出 | 1Mbps |
| 33–37 | `NC_PSRAM` | — | N16R8 Octal PSRAM 占用，禁止使用 |
| 38 | `MOTION_UART_RX` | 输入 | 1Mbps |
| 39 | `MUTE_SENSE` | 输入 | 物理静音开关状态；安全默认静音 |
| 40 | `IOEXP_IRQ_N` | 输入 | TCA9554 中断 |
| 41 | `HEAD_UART_TX` | 输出 | FFC 恢复通道 |
| 42 | `HEAD_UART_RX` | 输入 | FFC 恢复通道 |
| 43 | `U0TXD` | 输出 | 底座调试串口 |
| 44 | `U0RXD` | 输入 | 底座调试串口 |
| 45 | `NC_STRAP` | — | 绑带脚，不使用 |
| 46 | `NC_STRAP` | — | 绑带脚，不使用 |
| 47 | `MOTION_KILL_N` | 输出 | 硬件下拉，MCU 未配置时关闭电机 |
| 48 | `PA_ENABLE` | 输出 | 下拉；静音/故障先关功放 |

TCA9554：`P0=ENC_SW`、`P1=MUTE_LED`、`P2=USER_LED`、`P3=PD_INT_N`、`P4=HEAD_OC_N`、`P5=MOTOR_OC_N`、`P6=SPARE`、`P7=SPARE`。

### 8.2 HEAD-S3

Rev A 头部使用成熟 AMOLED 计算模组。屏幕、触控、IMU、RTC、Flash/PSRAM 的内部 GPIO **以该模组官方原理图为准，不在自研载板重新分配**。自研载板只使用官方 34Pin 扩展口已经引出的信号。冻结前必须在 `H-IO-001` Gate 用实物 + 原理图逐针通断验证。

| 扩展资源 | 载板用途 | 约束 |
|---|---|---|
| 模组 `UART_TX/RX` | 与 BASE-S3 的恢复/日志通道 | 3.3V；交叉连接 |
| 模组 `SDA/SCL` | Camera SCCB、载板低速 I/O | 先扫描板载地址，禁止冲突 |
| 4 个连续可用 GPIO | `HEAD_SPI_SCLK/MOSI/MISO/CS_N` | 由 `H-IO-001` 冻结具体脚号，10MHz SI 台架验证 |
| 3 个可用 GPIO | `HEAD_IRQ_N/HEAD_READY/SHUTTER_CLOSED_N` | `IRQ` 开漏优先；输入有安全默认值 |
| 头部 USB | 独立刷写与恢复 | 拆离底座或断开回灌路径后使用 |
| 5V/GND | 来自 `HEAD_5V` | 不接模组电池接口，不装电池 |

摄像头若因模组可用 GPIO 不足无法并接，不允许偷占屏幕/PSRAM脚。按优先级执行：

1. 使用模组官方已暴露且经验证的 DVP 接口；
2. 头部载板增加独立 XIAO ESP32-S3 Sense/等效视觉模组，AMOLED 模组只负责显示；
3. 进入自研 HEAD-S3 + QSPI AMOLED 的 Rev A.1；
4. 不得回退为让 BASE-S3 同时承担摄像头与音频。

这是一项有意保留的首板 Gate：当前公开资料确认模组有 34Pin 扩展，但在没有逐针实物核对前，不伪造确定的摄像头 GPIO 表。

### 8.3 MOTION-C3：ESP32-C3-MINI-1-N4

| GPIO | 信号 | 方向 | 备注 |
|---:|---|---|---|
| 0 | `PAN_IN1` | 输出/PWM | DRV8833 AIN1 |
| 1 | `PAN_IN2` | 输出/PWM | DRV8833 AIN2 |
| 2 | `TILT_IN1` | 输出/PWM | 绑带脚；外部必须保持默认启动电平，串阻后接驱动 |
| 3 | `TILT_IN2` | 输出/PWM | DRV8833 BIN2 |
| 4 | `PAN_ENC_A` | 输入 | MT6701 ABZ |
| 5 | `PAN_ENC_B` | 输入 | MT6701 ABZ |
| 6 | `TILT_ENC_A` | 输入 | MT6701 ABZ |
| 7 | `TILT_ENC_B` | 输入 | MT6701 ABZ |
| 8 | `PAN_LIMIT_N` | 输入 | 绑带脚；常闭回路 + 明确上拉，复位电平必须验证 |
| 9 | `TILT_LIMIT_N` | 输入 | 绑带脚；常闭回路 + 明确上拉，复位电平必须验证 |
| 10 | `DRV_FAULT_N` | 输入 | DRV8833 nFAULT，上拉 |
| 18 | `MOTION_UART_RX` | 输入 | BASE-S3 TX |
| 19 | `MOTION_UART_TX` | 输出 | BASE-S3 RX |
| 20 | `MOTION_HEARTBEAT` | 输出 | 独立脉冲供底座监测 |
| 21 | `DRV_nSLEEP` | 输出 | 10kΩ 下拉，复位默认关断 |

`EN/BOOT/UART` 独立引出。GPIO2/8/9 是 C3 绑带脚，首板必须用电阻网络保证上电状态；若限位结构无法保证高阻/正确电平，硬件评审必须把对应功能移到 TCA9534 或更换为 GPIO 更多的运动 MCU，禁止带风险下单。

### 8.4 I2C 地址表

| 总线 | 器件 | 7-bit 地址 | 备注 |
|---|---|---:|---|
| BASE `SYS_I2C` | ES7210 | `0x40`（默认候选） | 以 AD0/AD1 实际连接与 datasheet 复核 |
| BASE `SYS_I2C` | ES8311 | `0x18`（候选） | 以 CE/地址脚配置和实测扫描冻结 |
| BASE `SYS_I2C` | TCA9554 | `0x20` | A2:A0=000；与其他器件逐项核对 |
| BASE `SYS_I2C` | STUSB4500 | `0x28`（7-bit） | 只用于诊断/NVM 配置，不作为上电必需条件 |
| HEAD I2C | FT6336/IMU/RTC/扩展 | 以模组原理图为准 | 头部载板加器件前必须先生成扫描表 |

地址表在首板通电后以扫描结果校正；原理图地址脚、电阻默认值和软件配置必须三方一致。

## 9. 音频与 AEC 电路规则

### 9.1 双麦输入

- ES7210 只接两只同型号模拟 MEMS；当前工程中的 MSM261DHP006 数字麦必须删除/替换。
- MICBIAS、输入耦合、差分/单端模式、PGA 增益和高通配置严格按 ES7210 datasheet 与 Korvo-2 V3.1 参考图复核，禁止凭封装同名直接照抄。
- 两路麦克风的供电、阻容、走线长度和声学孔结构保持对称；模拟输入远离天线、电机、Buck SW 节点、扬声器差分输出和高速时钟。
- 每只麦克风旁放 100nF，模拟电源入口再放 1µF；实际值以麦克风 datasheet 为准。

### 9.2 播放与 AEC 参考

- `BASE-S3 → I2S → ES8311 DAC → NS4150B → 4Ω/3W`。
- AEC 参考从 **ES8311 Codec DAC 模拟输出、功放之前** 分支回 ES7210 的参考通道；不从扬声器功放输出直接取样。
- Codec→功放间保留 0Ω/RC/隔直与测试点，以便增益、底噪和 EMI 调整。
- `PA_ENABLE` 有硬件下拉；启动顺序为 Codec 稳定后开功放，停止顺序为先关功放再关 Codec，避免爆音。
- 扬声器 BTL 差分线成对走线，不与模拟麦输入平行；连接器靠板边，闭合电流回路面积最小。

### 9.3 静音硬件

锁定式开关同时产生两条效果：

1. 硬件关闭 `MIC_3V3A_SW` 或 ES7210/MICBIAS 有效采集路径；
2. 通过 `MUTE_SENSE` 告知 BASE-S3 并由独立硬件路径点亮红灯。

红灯不能完全依赖固件。若 MCU 死机，静音开关仍须切断采集且保持可见指示。解除静音后硬件恢复供电，但固件保持 `Idle`，不自动开始上传。

## 10. 保护电路

### 10.1 USB-C / PD

- CC1/CC2 直接按 STUSB4500 参考设计进入 U5；该器件本身对 CC 提供 22V short-to-VBUS 保护。普通 5V USB 数据 ESD 不能替代 CC 保护，`TPD2E2U06DRLR` 已删除。采用 PD 控制器时不得再并联普通 5.1kΩ Rd 破坏协商。系统级 IEC ESD 验证保持为 P1 台架项；未通过时再选择补强方案，不能在当前 CC 链路随意串接器件。
- VBUS 入口顺序：连接器 → 高压 TVS → `Q_PD1`（由 STUSB4500 控制）→ 输入保险/限流 → 主 Buck。STUSB4500 的 `VDD/VBUS` 监测、CC 及放电相关脚位接在 `Q_PD1` 前侧；不得把 PD 控制器放在被自身开关切断的后侧。
- USB D+/D− 各放 22Ω 串阻占位，ESD 靠连接器；差分线全程 90Ω，禁止测试点形成长支节。
- Shield 通过 1nF/1MΩ/可选 0Ω 网络接机壳/数字地，首板留 EMI 调整位，不在连接器处形成细长地颈。
- USB 口暴露网络、CC、VBUS 的 TVS/ESD 必须核对 VRWM、钳位电压、电容和封装方向。

### 10.2 电源分支

- `HEAD_5V` 与 `MOTOR_5V` 各自使用限流、软启动、过温和反向阻断器件；故障信号返回 BASE-S3。
- 主输入设置可恢复保险或 eFuse；额定值必须高于正常峰值而低于连接器、线缆与铜箔安全上限。
- 电机连接器旁放合适的 TVS/RC snubber/DNP 位；具体值依据示波器实测反电动势冻结。
- DRV8833 内部续流不能替代良好回流、VM bulk、热焊盘和近端去耦。
- 所有跨板输出在未供电时不得通过 IO 保护二极管回灌；必要时用串阻、bus switch 或具有 partial-power-down 的电平器件。

### 10.3 外部低速接口

- FFC 上所有外部可触达/长线信号放低电容 ESD 阵列；SPI/UART 每根保留 22–47Ω 源串阻。
- 编码器、限位与电机线分束；低速输入使用 RC + 施密特或数字滤波，连接器侧放 ESD。
- 限位使用常闭优先，断线、松脱或连接器未插入必须进入安全故障，而不是“未触发”。

## 11. 去耦、接地与滤波

### 11.1 通用规则

- 每个数字电源脚 1 颗 100nF X7R，距离焊盘尽可能小，每颗电容独立短过孔接完整地平面。
- 每个 IC 电源域至少再放 1µF；每个板卡电源入口放 10µF + 100nF；容量需按实际 DC Bias 降额。
- ESP32-S3 模组 3V3 入口至少 22µF + 10µF + 100nF，并按乐鑫硬件指南处理 EN RC、晶振/天线禁布区。
- 开关电源输入/输出电容、电感、SW 节点严格按 datasheet 推荐布局；SW 铜皮最小，不得跨越模拟区或地分割。
- 不割裂主 GND 平面。用器件分区和受控回流隔离噪声；模拟地与数字地若使用网桥，只允许在 Codec/ADC 推荐位置单点连接并经评审。

### 11.2 分域策略

| 域 | 去耦/滤波基线 |
|---|---|
| `BASE_3V3` | Buck 近端按 datasheet；S3 模组入口 22µF + 10µF + 多颗 100nF |
| `AUDIO_3V3A` | TPS7A20 输入 2.2µF、输出 2.2–4.7µF 起始；每颗 Codec/MIC 再本地去耦，最终以 datasheet 稳定范围为准 |
| `HEAD_5V` | FFC 两端各 47–100µF low-ESR + 1µF + 100nF；先确认模组允许的输入纹波与浪涌 |
| `MOTOR_5V` | eFuse 后 470µF 电解/固态 + 10µF + 100nF 起始；DRV8833 VM 近端 10µF + 100nF，按堵转波形修订 |
| 功放 | 5V 入口 220µF + 10µF + 100nF 起始，BTL 回流不得穿过麦克风/ADC 地参考 |

磁珠只用于经实测证明需要的敏感分支，首板可留 `0Ω/FB` 兼容位；不能用磁珠弥补错误回流或割裂地平面。

## 12. PCB 层叠与布局布线

### 12.1 层叠

Base、Head Carrier 均采用嘉立创可稳定生产的 4 层板，建议 1.6mm、1oz 外层；最终介质厚度和阻抗线宽在下单前以嘉立创阻抗计算/叠层表为准。

| 层 | 主要用途 | 规则 |
|---|---|---|
| L1 | 器件、关键高速/模拟信号 | USB、时钟、模拟前端最短；连续 GND 参考 |
| L2 | 完整 GND 平面 | 不分割；关键线下方不得开槽 |
| L3 | 5V/3V3 电源面 + 慢速信号 | Motor、Audio、Head 分区；避免高速跨电源面边界 |
| L4 | 低速信号、辅助地铜 | 连接器/调试；密集地过孔缝合 |

Encoder 小板可用 2 层，但传感器下方、磁铁对位、安装公差和地铜按 MT6701 datasheet/机械验证处理。

### 12.2 放置优先级

1. 结构冻结件：USB-C、FFC、扬声器、电机/编码器/限位、旋钮、静音、安装孔、天线边界。
2. 电源入口和主 Buck：以最小高 di/dt 回路布局。
3. 音频链路：麦克风 → ES7210、ES8311 → 功放 → 扬声器，保持物理隔离。
4. BASE-S3：天线靠板边并满足乐鑫全层禁铜/禁器件区。
5. MOTION-C3/DRV8833：靠电机连接器和 Motor bulk，远离麦克风/Codec。
6. Head FFC 和保护/串阻：保护靠连接器，源串阻靠驱动端。
7. 调试口、测试点和 DNP 调整位。

### 12.3 关键约束

- USB2 D+/D−：90Ω 差分、等长、同层、少过孔、连续参考面；不穿 Buck/电机/天线区。
- I2S MCLK/BCLK/LRCK：源端串阻占位，彼此及与模拟输入保持间距，下面连续地。
- Head SPI：10MHz 起步，时钟有相邻 GND 回流针；FFC 两端不得形成未端接长支路。
- 模拟麦线：差分/成对、等环境、无测试长支节；不得从 ESP32 天线、Buck SW、DRV8833 和扬声器线下方穿过。
- 电机线：宽线/铜皮按堵转电流和温升计算；最小化 H 桥—电机—回流环路；热焊盘用多过孔接地散热。
- 电源：5V 主干、Head、Motor 铜宽按 6A/1.5A/2.5A 峰值和允许温升计算，不采用默认细线。
- 所有板边连接器周围建立 ESD 到地的最短泄放路径；ESD 电流不能穿过 MCU/Codec 地回路。
- 头部 FFC 在双轴全行程下不受拉、不折死、不与锐边摩擦；PCB 完成不代表线束寿命通过。

## 13. 测试点与可恢复性

至少保留以下测试点：

- 电源：`VBUS_PD`、`12V_IN`、`5V_SYS`、`BASE_3V3`、`AUDIO_3V3A`、`HEAD_5V`、`MOTOR_5V`。
- 复位/启动：三颗 MCU 的 `EN/BOOT/UART_TX/UART_RX`。
- USB：D+/D− 不放形成长 stub 的大测试点；使用专用低支节焊盘。
- 音频：MCLK、BCLK、LRCK、ADC_SDOUT、DAC_DSDIN、Codec 模拟输出/AEC 参考、功放输入。
- 通信：Head SPI 四线、IRQ/READY，Motion UART、heartbeat、kill。
- 运动：四路 H 桥输入、`nSLEEP`、`nFAULT`、两轴编码器 A/B、两轴限位。

三颗 MCU 均必须可独立恢复，不依赖另一颗 MCU 正常运行。OTA 分区启用 rollback；底座只协调版本兼容，不得在头部升级失败时覆盖其可回滚镜像。

## 14. 嘉立创 EDA 执行规则

1. 只通过嘉立创 EDA 专业版 GUI 或官方导入/导出能力编辑 `Hushlight.eprj2`；禁止直接修改其 SQLite/压缩历史数据库。
2. 每次大改前复制工程快照并导出 PDF 原理图；文件名含 `hw_rev` 和日期。
3. 位号按功能使用：`U` IC、`J` 连接器、`MIC` 麦克风、`SW` 开关、`ENC` 旋钮、`TP` 测试点。当前误标为 `U5/U8/U9` 的排针必须重注释为 `J`。
4. 第三方符号/封装必须逐脚对照 datasheet；特别核对 QFN EP、连接器 pin-1、FFC 同面/异面、USB-C A/B 并脚和模组天线方向。
5. 原理图采用分层网络名，不用跨页长导线；电源网络名必须唯一，不混用 `VCC/5V/VBUS`。
6. ERC 中不允许用全局忽略掩盖未连接电源脚、输出冲突和悬空输入；例外逐条写入审查记录。
7. 在原理图评审、Pin Budget、功耗预算和关键样件验证通过前，不生成可下单 Gerber/BOM/坐标文件。
8. 任何“下单/采购/贴片”操作需要项目发起人单独批准；本文不构成采购授权。

## 15. 当前工程对账与返工清单

对 `Hushlight.eprj2` 当前放置状态执行以下纠偏：

| 当前项 | 处理 |
|---|---|
| U1 ESP32-S3-WROOM-1-N16R8 | 保留为 `BASE-S3` |
| U2 NS4150B、U3 ES8311、U4 ES7210 | 保留，按本文重新完成外围与网络 |
| U6/U7 MSM261DHP006 | 删除或移出 BOM；替换为两只模拟 MEMS |
| 1×4/1×2 排针被标为 U | 重注释为 J 类连接器 |
| `01POWERUSB` 的 5V/2A 占位 | 改为 STUSB4500 + 12V→5V/6A + 分域电源树 |
| `06-MOTION-IO` 只有接口占位 | 加入 MOTION-C3、DRV8833、编码器和常闭限位电路 |
| Head 原理图为空 | 改为 Head Carrier：AMOLED 模组连接、摄像头、隐私、FFC、保护与调试 |
| 2.4 英寸 320×240 屏假设 | 只保留 Korvo-2 参考线；自研首板升级 2.41 英寸 600×450 AMOLED |

## 16. 设计 Gate

### G0：文档与器件

- [ ] 每颗 `FROZEN-A` 器件的制造商、完整料号、datasheet 版本、封装、温度等级和供货状态已记录。
- [ ] 嘉立创符号与封装逐脚核对，双人复核关键器件与连接器。
- [ ] `H-IO-001` 完成：AMOLED 模组 34Pin 实物/原理图逐针核对，确认 Head SPI、UART、摄像头与安全信号的可用 GPIO。
- [ ] 摄像头、磁编码器、电机/减速箱完成样件台架，不以网页规格替代实测。

### G1：原理图

- [ ] 电源树、最坏功耗、堵转电流、PD 降级模式和时序计算通过评审。
- [ ] 三颗 MCU GPIO/绑带/USB/Flash/PSRAM 冲突检查通过。
- [ ] I2C 地址、上拉与电容预算通过。
- [ ] 静音、限位、kill、nSLEEP 在 MCU 未运行时进入安全态。
- [ ] ERC 无未解释错误；原理图 PDF、BOM 草案和 Pin Budget 存档。

### G2：PCB

- [ ] 4 层叠层和 USB 90Ω 阻抗由板厂参数确认。
- [ ] 天线禁布、音频、电源高 di/dt、电机热设计和 ESD 泄放路径完成专项 review。
- [ ] FFC 电流、弯折半径、全行程长度与头部重心由结构工程师联审。
- [ ] DRC 通过；3D 装配和连接器方向检查通过。

### G3：下单前

- [ ] 关键料号库存、替代、含税成本和交期重新核价。
- [ ] 原理图/PCB/BOM/坐标文件版本一致且生成只读归档。
- [ ] 硬件工程师签字，项目发起人明确批准打板与采购。

### G4：首板通电与效果

- [ ] 限流电源分轨上电；12V、5V、3V3、音频、Head、Motor 逐级验证。
- [ ] 三颗 MCU 独立刷写、复位、看门狗、OTA rollback 通过。
- [ ] 满亮屏 + 摄像头 + 60% 扬声器 + 双轴动作无重启/brownout；记录电源波形。
- [ ] 电机动作期间音频底噪、AEC、唤醒与 ASR 不显著劣化。
- [ ] Head/Motion 任一断线时基础语音仍可用且明确降级。
- [ ] 运动超时、断线、编码器异常、限位触发和机械堵转全部安全停机。
- [ ] 角色动画、触摸和 10 人表现力对比达到 08 文档 Gate。

## 17. 待冻结事项与 Owner

| ID | 事项 | Owner | 截止 Gate |
|---|---|---|---|
| `H-IO-001` | 头部 AMOLED 模组扩展 GPIO、摄像头并接能力和连接方式实测 | 硬件 + 固件 | G0 |
| `H-CAM-001` | OV3660/OV5640 模组、镜头 FOV、低照度、帧率和功耗对比 | 视觉固件 + 硬件 | G0 |
| `H-MOT-001` | 电机额定/堵转电流、减速比、噪声、回差、速度与头部惯量 | 结构 + 硬件 | G0 |
| `H-ENC-001` | MT6701 磁铁、气隙、同心度、磁干扰和重复精度 | 硬件 + 结构 | G0 |
| `H-PWR-001` | Head/Motor eFuse 的 `ILIM`、软启动与故障时间常数实测冻结 | 硬件 | G1 |
| `H-MIC-001` | 模拟 MEMS 完整料号、封装与声学样件 | 音频 + 硬件 | G0 |
| `H-FFC-001` | 30Pin FFC 连接器具体料号、同面/异面与线束寿命 | 硬件 + 结构 | G2 |

## 18. 关键资料核对记录

| 器件/主题 | 核对资料 | 已用于本文的关键事实 |
|---|---|---|
| ESP32-S3-WROOM-1 | [官方 Datasheet V1.8](https://documentation.espressif.com/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf)、[硬件设计指南](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32s3/) | N16R8 容量、Octal PSRAM 占用、绑带/USB/UART、天线与电源规则 |
| ESP32-C3-MINI-1 | [官方 Datasheet V2.2](https://documentation.espressif.com/esp32-c3-mini-1_datasheet_en.html) | 15 GPIO、GPIO2/8/9 绑带、UART/TWAI/LEDC 能力 |
| Korvo-2 音频 | [V3.1 官方原理图](https://dl.espressif.com/dl/schematics/SCH_ESP32-S3-Korvo-2_V3.1.2_20240116.pdf)、[开发板指南](https://docs.espressif.com/projects/esp-adf/en/latest/design-guide/dev-boards/user-guide-esp32-s3-korvo-2.html) | ES7210 + ES8311 + NS4150、模拟 MEMS 与 AEC 参考拓扑 |
| ES7210 | [Datasheet Rev 21.0](https://files.waveshare.com/wiki/common/ES7210_DS.pdf) | 四路 ADC、I2S/TDM、MICBIAS、地址/外围待逐脚复核 |
| ESP32 摄像头 | [Espressif 官方 esp32-camera](https://github.com/espressif/esp32-camera)、[Seeed XIAO S3 Sense 官方资料](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/) | OV3660/OV5640 驱动路径、PSRAM 与 DVP 参考 |
| AMOLED 模组 | [Waveshare 产品资料](https://www.waveshare.com/product/esp32-s3-touch-amoled-2.41.htm)、[官方原理图](https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-2.41/ESP32-S3-Touch-AMOLED-2.41-Schematic.pdf) | 2.41 英寸、600×450、RM690B0 QSPI、FT6336、8MB PSRAM/16MB Flash、34Pin 扩展 |
| RM690B0 | [Datasheet V0.3](https://files.waveshare.com/wiki/common/RM690B0_DataSheet_V0.3_20210105_%28Public_version%29.pdf) | QSPI 与 480RGB×600 上限；显示初始化仍以具体模组 BSP 为准 |
| STUSB4500 | [ST 官方 Datasheet Rev 8](https://www.st.com/resource/en/datasheet/stusb4500.pdf) | 自动 PD Sink、最多三个 PDO、20V/5A 能力与 CC/VBUS 保护边界 |
| TPS56637 | [TI 产品与 Datasheet](https://www.ti.com/product/TPS56637) | 4.5–28V 输入、6A 同步 Buck |
| TPS62132 | [TI 产品与 Datasheet](https://www.ti.com/product/TPS62132) | 3–17V 输入、固定 3.3V、3A Buck；嘉立创器件 `TPS62132RGTR / C81563` |
| TPS7A20 | [TI Datasheet Rev H](https://www.ti.com/lit/ds/symlink/tps7a20.pdf) | 300mA、7µVrms、95dB@1kHz、最小 1µF 稳定条件 |
| TPS259470 | [TI Datasheet Rev C](https://www.ti.com/lit/ds/symlink/tps25947.pdf) | 2.7–23V、真反向阻断、0.5–6A 可调限流、软启动、故障输出；嘉立创 `C3662799` |
| DRV8833 | [TI Datasheet Rev E](https://www.ti.com/lit/ds/symlink/drv8833.pdf) | 2.7–10.8V、双 H 桥、PWP 1.5A RMS/2A peak、保护与限流 |
| MT6701 | [制造商 Datasheet 镜像](https://datasheet.lcsc.com/lcsc/2109011830_Magn-Tek-MT6701CT-STD_C2856764.pdf) | 磁角度反馈候选；机械与磁场约束必须样件验证 |
| ESP32-P4 | [官方 Datasheet](https://documentation.espressif.com/esp32-p4_datasheet_en.html) | 高性能视觉能力与 pre-release 状态，支撑 Rev B 而非 Rev A 的判断 |

资料核对不等于参考电路已完成，也不等于器件可采购。进入 G1 前，硬件工程师还需逐页核对推荐工作条件、封装 land pattern、外围计算和勘误；进入 G3 前重新核价与确认库存。
