# 小熙 Hushlight H0C Rev A Gate 样件采购与到货核验清单

> 版本：V1.4
> 更新日期：2026-08-21
> 状态：第一批验证样件可据此采购；最终结构件、PCB BOM 和量产料号仍受 Gate 控制
> 权威上游：[10_hardware_board_design_spec.md](10_hardware_board_design_spec.md)、[07_decisions.md](07_decisions.md)

## 1. 采购规则

本轮目标是取得能关闭 `H-IO-001/H-CAM-001/H-MOT-001/H-ENC-001/H-MIC-001/H-FFC-001` 的实物证据，不把样件采购误当成最终 BOM 冻结。

| 状态 | 含义 | 允许动作 |
|---|---|---|
| `BUY-SAMPLE` | 型号明确，可直接用于 Gate 验证 | 核对商品页后采购 |
| `RFQ-FIRST` | 标题不足以证明接口或机械条件 | 先向卖家索取资料，资料通过后再买 |
| `HOLD` | 依赖其他实物或原理图结果 | 暂不采购，不接受“相近替代” |
| `RISK-STOCK` | 已冻结 IC 的备料，不代表允许做 PCB | 仅库存/交期确有风险时少量锁货 |

只有“兼容”“N20”“OV3660”“30Pin FFC”等泛称的商品，不足以关闭任何 Gate。商品页必须出现制造商完整型号或 SKU。

### 采购执行顺序

| 优先级 | 现在怎么做 | 条目 |
|---|---|---|
| A：可直接下单 | 按完整型号/SKU 买样件；保留订单页面、批次和外包装标签 | P-02、P-03、P-07～P-09、P-11～P-15、P-18、P-19、P-22、P-23、R-12、R-13 |
| B：先发 RFQ，再买 | 将本清单的完整型号/规格原样发给供应商，必须拿到资料和报价再确认 | P-01、P-04～P-06、P-10、P-16、P-20、P-21 |
| C：暂不买 | 不是本版启动条件，避免提前买成旧路线或错误接口 | P-01A、最终 Head/FFC/相机连接器与全套 PCB 料 |

`RISK-STOCK` 仅适合少量锁货；它不授权下 PCB，也不表示外围参数已经冻结。

## 2. 第一批：建议现在采购

### 2.1 Head、显示与视觉

| ID | 状态 | 完整型号/SKU | 数量 | 用途与采购前确认 |
|---|---|---|---:|---|
| P-01 | `RFQ-FIRST` | **2.4 英寸 320×240 IPS LCD + 电容触控**的横屏产品目标；优先询价两款指定屏：`KD024QVFMA020-C003A`（ST7789V + FT6336G，42.92×60.26×3.75mm，400nit）；`KD024QVFMA070-01-C021B`（ST7789V + FT5436，48.72×70.26×3.95mm，500nit、45Pin/0.3mm） | 各 1 | 两者均为原生 240×320 IPS+CTP，可由 UI 横屏呈现 320×240。优先先拿 C003A 的完整 FPC 图和样件；第二款用于亮度、尺寸、FPC 难度对照。必须确认 LCD/触控完整料号、接口模式（I80 8bit 优先，SPI 只作低帧率备选）、FPC Pin 1、时序、背光电压/电流、千台含税报价和交期。实物通过 20fps、触控、纹波、可视角和 Head-S3 GPIO/DMA 后冻结。 |
| P-01A | `HOLD` | 2.4 英寸 600×450 AMOLED 裸屏 + 触控，非开发模组 | 0 | 后续市场反馈证明高显示表现具备付费需求后，才启动独立版本询价；不得用于本版消费 BOM 或替代 P-01。 |
| P-02 | `BUY-SAMPLE` | Seeed Studio `XIAO ESP32S3 Sense`，SKU `113991115` | 2 | Seeed 已发布 OV2640→OV3660 变更；付款前要求卖家书面确认当前批次为 OV3660并保存截图。用于视觉备份路线。 |
| P-03 | `BUY-SAMPLE` | Seeed `OV5640 Camera for XIAO ESP32S3 Sense (With Heat Sink)`，SKU `114993115` | 1 | 用于 OV3660/OV5640 画质、对焦、温升和低照度对比；不等于最终 Head Carrier 相机。 |
| P-04 | `RFQ-FIRST` | OV3660 或 OV5640、**8bit DVP 并口**、HFOV `80°–100°` 的裸相机模组 | 最多 2 型号、各 1 | RFQ 必填：传感器和镜头完整料号、IR-cut、有无 AF、XCLK/PCLK/VSYNC/HREF/D0～D7、SCCB、各电源轨、FPC 针数/间距/同异面、模组尺寸和真实 HFOV。只给“OV3660 广角”标题、未给 pinout 的不采购。 |

P-01 是消费版自研 Head 的显示 Gate，不采购零售显示计算开发模组。P-02 的同一 SKU 存在摄像头批次变化，订单批次证据必须留存。

### 2.2 运动、编码器与限位

| ID | 状态 | 完整型号/SKU | 数量 | 用途与采购前确认 |
|---|---|---|---:|---|
| P-05 | `RFQ-FIRST` | **Pan RFQ 基线**：NFP `NFP-GM12-N20W` 族对应的 6V / 0.4W / 35 Type / `100:1` / Ø3×L9mm 输出轴 / 无编码器配置 | 2 | NFP 公布的性能 PDF 标作 `NFP-GM15-N20W`，与既有 `GM12` 族名称不一致，故**不能自行把 GM15 当最终料号**。该 PDF 的目标标称点为 120rpm 空载、80rpm 额定、0.4kg·cm 额定扭矩、≤0.27A 额定、≤0.65A 堵转。订单须由 NFP/供应商书面写明真实制造商料号、6V 35 Type、100:1、轴形（D 轴平面尺寸）、轴长、齿隙、噪声、寿命、批次和千台含税报价；与 MT6701 输出轴闭环及 3:1 GT2 同台验证。 |
| P-06 | `RFQ-FIRST` | **Tilt RFQ 基线**：NFP `NFP-GM12-N20W` 族对应的 6V / 0.4W / 35 Type / `150:1` / Ø3×L9mm 输出轴 / 无编码器配置 | 2 | 同 P-05 的料号歧义必须由供应商关闭；目标标称点为 80rpm 空载、52rpm 额定、0.6kg·cm 额定扭矩、≤0.27A 额定、≤0.65A 堵转。下单前确认项与 P-05 相同；在同 Head 质量、重心和线束条件下验证连续扭矩、80°/s、回差、温升、噪声、AEC/唤醒干扰和寿命。 |
| P-07 | `BUY-SAMPLE` | Texas Instruments `DRV8833EVM` | 2 | 作为双 H 桥、PWM、刹车/滑行、限流、nSLEEP/nFAULT 电气基准；不以无原理图通用小板替代首轮基准。 |
| P-08 | `BUY-SAMPLE` | Espressif `ESP32-C3-DevKitM-1` | 2 | 验证 GPIO2/8/9 绑带、1kHz 控制、UART 和限位安全态；记录模组完整后缀。 |
| P-09 | `BUY-SAMPLE` | MagnTek `MT6701CT-ACD-R`，SOP-8；LCSC `C3202694` | 10 | AB 输出 1024 脉冲/圈；不买 `MT6701CT-STD/C2856764`（AB 仅 1 脉冲/圈），验证气隙、偏心、重复精度和磁干扰。 |
| P-10 | `RFQ-FIRST` | 钕铁硼 **直径向/径向充磁**磁铁，`Ø6×2.5mm`，N35 或更高，Ni-Cu-Ni 镀层 | 20 | 卖家必须书面确认直径向/径向充磁并给方向图；轴向充磁禁止采购。20 颗含两轴装配、气隙/偏心试验和备品，不代表量产用量。 |
| P-11 | `BUY-SAMPLE` | Omron/Aratas `D2F-01L`，SPDT 直杠杆 PCB 端子 | 6 | 核对 COM/NC/NO；用于 NC 断线故障和机构行程。 |
| P-12 | `BUY-SAMPLE` | Omron/Aratas `D2F-L-D3`，SPDT 直杠杆焊片端子 | 4 | 与 P-11 比较 PCB/线束安装；最终型号由安装面决定。 |
| P-13 | `BUY-SAMPLE` | GT2（2mm pitch）/6mm 宽；**3mm 孔** `16T` 主动轮 ×3、`48T` 从动轮 ×3、6mm 张紧件 ×2、6mm 开口皮带 ≥2m | 1 批 | 两个轴各需一组 3:1；多出的各一只为装配备件。皮带用开口料在台架上量出中心距后再裁切/订闭环长度，最终闭环长度仍为 HOLD。下单前确认轮孔为 3mm（非 2mm）、皮带宽 6mm（非 9mm）且螺钉不会顶到 D 轴平面。 |

P-05/P-06 是消费版 N20 RFQ/样件 Gate，不以电机端编码器替代输出轴 MT6701。候选必须在当前单轴 ≤1.2A 的设计包络内；DRV8833 PWP/RTY 每桥为 1.5A RMS、2A 峰值，最终仍须按实际 PCB 散热、限流和双轴同时动作实测。

### 2.3 音频、静音与扬声器

| ID | 状态 | 完整型号/SKU | 数量 | 用途与采购前确认 |
|---|---|---|---:|---|
| P-14 | `BUY-SAMPLE` | Infineon `IM73A135V01XTSA1` | 10 | 必须是模拟差分 `V01`，不得以 PDM 数字麦替代；验证相位、底噪、隔振和双麦一致性。 |
| P-15 | `BUY-SAMPLE` | PUI Audio `AS04004PR-R`，40mm、4Ω、3W | 2 | 核对 40mm 直径、17.5mm 高度和焊片；验证声压、失真、音腔和 NS4150B 热负载。 |
| P-16 | `RFQ-FIRST` | TE Connectivity `1825265-1` / Alias `MSS4200R04`，4PDT、ON-ON、直角 THT | 2 | TE 标记 Active 但当前不直接供货；先确认授权分销库存和完整标签。用 3 组验证麦电源、红灯、`MUTE_SENSE`，第 4 组备用。 |
| P-17 | `BUY-SAMPLE` | 防尘透声膜、金属网、硅胶隔振垫、闭孔泡棉 | 各 1 包 | 记录厚度、透气/防水等级和胶层；麦克风不得与扬声器共腔。 |

P-16 只冻结“至少 3 组独立保持触点”的电气候选。替代件必须先提交 datasheet、触点图、尺寸图和商品链接，不接受只凭照片判断。

### 2.4 FFC 与 PD 台架

| ID | 状态 | 完整型号/SKU | 数量 | 用途与采购前确认 |
|---|---|---|---:|---|
| P-18 | `BUY-SAMPLE` | Molex `150780930`，30Pin/0.5mm/229mm/Type A 同面 | 2 | 仅做 Pin 1、方向、长度和机构样件；单针 0.35A，不关闭 Head 电流 Gate。 |
| P-19 | `BUY-SAMPLE` | Molex `150782930`，30Pin/0.5mm/229mm/Type D 异面 | 2 | 与 P-18 对比。四根 `HEAD_5V` 只有 1.4A 标称合计，低于当前 1.5A 峰值。 |
| P-20 | `RFQ-FIRST` | Molex `15166` Ultra-Flex 或有等效寿命证明的 30Pin/0.5mm 定制件 | A/D 各 2 | 要求长度、端厚、单针电流、最小弯折半径和寿命曲线；没有规格书不买为最终件。 |
| P-21 | `RFQ-FIRST` | 明确列出 `12V/3A` PDO 的 USB-C PD 电源 + 3A C-to-C 线 | 1 套 | 只写 65W/100W 不足以证明 12V；先取得完整 PDO 表。 |
| P-22 | `BUY-SAMPLE` | ChargerLAB / POWER-Z `KM003C` | 1 | 可做 PDO/协议测试、触发、e-marker 与 PC 数据记录；普通 USB 电流表不满足。购买官方渠道，保留固件版本和说明书。 |
| P-23 | `BUY-SAMPLE` | Espressif `ESP32-S3-DevKitC-1-N8R8` ×2；最终 Base 模组另按 R-01 的 `ESP32-S3-WROOM-1-N16R8` 备料 | 2 块 + R-01 | `DevKitC-1-N8R8` 是官方 3.3V/8MB PSRAM 开发板变体，足以做 Base 软件台架；16MB Flash/8MB PSRAM 是最终模组要求，不能把 `N16R8` 误写成该开发板的订货型号。 |

## 3. 询价与采购回填

| 询价对象 | 必须向卖家索取 | 通过条件 |
|---|---|---|
| 最终相机 | 正反面、传感器/镜头、HFOV、DVP/FPC pinout、FPC 尺寸/同异面、电压、帧率 | 型号与资料一一对应；目标距离实测后冻结 |
| 最终 IPS 屏/触控 | 屏和触控完整料号、controller、接口、FPC pinout、Pin 1、时序、亮度、工作温度、ESD 建议、千台含税报价和交期 | Head-S3 上达到 20fps、触控 P95 <150ms，且资料、样件、原理图、BOM 一致 |
| 直径向磁铁 | 尺寸、镀层、磁材、充磁方向图 | 明确直径向/径向，不接受“强磁圆柱” |
| 动态 FFC | 系列、针数、间距、A/D、长度、端厚、电流、弯折半径和寿命 | 电流与寿命同时满足；不足时先改 30Pin 电源分配 |
| PD 电源 | 全部固定 PDO、线缆能力 | 明确包含 12V/3A，实物再由分析仪复核 |
| 替代开关 | 完整料号、触点图、保持方式、寿命、尺寸/开孔、在产状态 | 静音至少 3 个独立保持触点；快门有两条独立硬件事实通路 |

| ID | 实际商品完整标题 | 商品链接 | 卖家/渠道 | 订单型号/SKU | 数量 | 下单日期 | 到货照片路径 | 结论 |
|---|---|---|---|---|---:|---|---|---|
|  |  |  |  |  |  |  |  |  |

下单前可把链接填入本表或直接发给我复核。到货后先拍外包装标签、正反面、连接器和 Pin 1，再拆装测试。

## 4. 暂不采购

| 项目 | 停止原因 | 放行证据 |
|---|---|---|
| Head LCD/触控最终 FPC 座与保护 | P-01 的 FPC、Pin 1、时序和控制器尚未冻结 | 实物尺寸、通断、3D 装配、20fps/触控测试 |
| Base/Head 最终 30Pin FFC 座 | A/D、安装面和最终动态 FFC 未冻结 | P-18/P-19 试装 + P-20 规格 + 两端 Pin 1 |
| 30Pin FFC 最终电源分配 | 4×0.35A=1.4A，低于 1.5A 峰值 | 增加电源针、降低实测峰值或换高额定线缆，并记录决策 |
| 最终 Head 相机、FPC 座和 ESD | 取决于 IPS 屏/触控与 P-04 的 GPIO/DMA/FPC 接口 | `H-IO-001/H-CAM-001` 关闭 |
| 最终静音开关和开孔 | P-16 仅验证电气逻辑 | 触点真值表、开孔、寿命、断线默认静音 |
| 快门量产开关 | 小型 DPDT 行程件未冻结；先用同一快门凸轮驱动两颗独立 SPDT 验证 | 一路断相机电源、一路输出 `SHUTTER_CLOSED_N`，验证时序/失效 |
| 最终电机、皮带、支架、轴承 | 依赖 Head 质量、重心、惯量和线束阻力 | `H-MOT-001` 与 CAD 装配 |
| 最终电机/编码器/限位连接器与保护 | 取决于线长、线序和反电动势 | 实物线序、示波器、EMI/ESD 方案 |
| 完整 PCB 被动料、连接器、ESD、TVS、散热件 | 多页接线、ERC、封装未完成 | G1 原理图、ERC、BOM/PCB 一致 |

## 5. IC 风险备料：默认不随第一批下单

| ID | 状态 | 器件 | 当前订货号 | 建议数量 | 备注 |
|---|---|---|---|---:|---|
| R-01 | `RISK-STOCK` | Base 主控 | `ESP32-S3-WROOM-1-N16R8` | 5 | 天线布局仍受 PCB Gate 控制 |
| R-02 | `RISK-STOCK` | Motion 主控 | `ESP32-C3-MINI-1-N4` | 5 | GPIO2/8/9 绑带先审查 |
| R-03 | `RISK-STOCK` | 电机驱动 | `DRV8833PWPR` / LCSC `C50506` | 5 | PWP PowerPAD |
| R-04 | `RISK-STOCK` | PD Sink | `STUSB4500QTR` | 5 | 先做 NVM PDO 台架 |
| R-05 | `RISK-STOCK` | 主 Buck | `TPS56637RPAR` | 5 | 外围/波形受 G1 控制 |
| R-06 | `RISK-STOCK` | 3.3V Buck | `TPS62132RGTR` / LCSC `C81563` | 5 | 不得误购 TPS62133 |
| R-07 | `RISK-STOCK` | 音频 LDO | `TPS7A2033PDBVR` / LCSC `C2862740` | 5 | 3.3V 音频域 |
| R-08 | `RISK-STOCK` | Head/Motor eFuse | `TPS259470ARPWR` / LCSC `C3662799` | 10 | ILIM/软启动待实测 |
| R-09 | `HOLD` | ES7210/ES8311/NS4150B | 完整后缀/封装/授权来源待复核 | 0 | 不凭系列名买裸 IC |
| R-10 | `RISK-STOCK` | I²C 扩展 | `TCA9554PWR` | 5 | 地址/上拉待 G1 |
| R-11 | `RISK-STOCK` | 麦 LDO | `TPS7A2028PDBVR` | 5 | `MIC_2V8_LDO` |
| R-12 | `RISK-STOCK` | Head 主控 | `ESP32-S3-WROOM-1-N16R8` / LCSC `C2913202` | 5 | Head S0 已确认使用该模组；天线禁布、供电与 GPIO 尚受 G1/`H-IO-001` 约束，锁货不等于下单 PCB。 |
| R-13 | `RISK-STOCK` | Head 5V→3V3 Buck | `TPS62132RGTR` / LCSC `C81563` | 5 | 首板与 Base 复用同一 3.3V/3A 稳定性基线；Head 峰值、显示偏压和外围值仍待 P-01/P-04、`H-PWR-001`。 |

## 6. 到货后 Gate 关闭顺序

1. R-12/R-13：若按风险备料下单，保留嘉立创订单型号与批次；它们只支持 Head 原理图起步，不关闭 Head 供电或 PCB Gate。
2. P-01：记录订单、背标、屏/触控完整料号、FPC Pin 1、controller、时序和 Head-S3 GPIO/DMA 可用性。
3. P-02/P-03/P-04：固定距离、照度和分辨率做同场景对比，决定相机路径。
4. P-05 至 P-13：先空载，再限流堵转；记录电流、转速、噪声、温升、回差、编码器和 NC 限位。
5. P-14 至 P-17：完成双麦、电气静音、红灯、`MUTE_SENSE`、扬声器和隔振。
6. P-18 至 P-20：完成方向、通断、压降、温升、弯折半径和全行程寿命，再冻结连接器和电源针数。
7. P-21/P-22：记录 5/9/12V PDO、掉电和峰值负载。
8. Gate 只在“订单型号 + 实物照片 + 数据手册 + 测试记录”齐全后关闭，再更新分页接线清单和最终缺件。

## 7. 资料

- IPS/触控完整资料由 P-01 RFQ 回填；未回填前不得开始 `01-DISPLAY-TOUCH` 放件。
- [Waveshare 2.41 产品页](https://www.waveshare.com/esp32-s3-touch-amoled-2.41.htm)（仅后续 AMOLED 候选参考，非本版采购输入）
- [Seeed XIAO ESP32S3 Sense](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/)
- [Seeed 摄像头变更 PCN](https://files.seeedstudio.com/wiki/SeeedStudio-XIAO-ESP32S3/res/PCN-XIAO_ESP32-S3_Sense_Series_Camera_Upgrade.pdf)
- [Seeed OV5640 SKU 114993115](https://www.seeedstudio.com/OV5640-Camera-for-XIAO-ESP32S3-Sense-With-Heat-Sink-p-5739.html)
- [Startek `KD024QVFMA020-C003A`](https://www.startek-lcd.com/product/474-KD024QVFMA020-C003A-2.4-inch-240x320-ST7789V-IPS-LCD-module-with-build-in-capacitive-touch-panel.html)
- [TFT-TFT `KD024QVFMA070-01-C021B`](https://www.tft-tft.com/product/detail?id=484)
- [NFP N20 35 Type 性能表](https://nfpshop.com/wp-content/uploads/2026/06/DATA-SHEET-NFP-GM15-N20W.pdf)（采购前须关闭 `GM12`/`GM15` 型号命名歧义）
- [TI DRV8833](https://www.ti.com/product/DRV8833)、[DRV8833EVM](https://www.ti.com/tool/DRV8833EVM)
- [MagnTek MT6701](https://www.magntek.com.cn/upload/pdf/202407/MT6701_Rev.1.8.pdf)
- [Infineon IM73A135V01](https://www.infineon.com/assets/row/public/documents/24/49/infineon-im73a135-datasheet-en.pdf)
- [Omron/Aratas D2F](https://components.omron.com/system/files/2025-01/datasheet_pdf/CDLA-038.pdf)
- [TE Connectivity 1825265-1 / MSS4200R04](https://www.te.com/en/product-1825265-1.html)
- [PUI Audio AS04004PR-R](https://www.digikey.com/en/products/detail/pui-audio-inc/AS04004PR-R/3189932)
- [Molex Type A 150780930](https://www.molex.com/en-us/products/part-detail/150780930)、[Type D 150782930](https://www.molex.com/en-us/products/part-detail/150782930)、[Premo-Flex 选型](https://www.molex.com/content/dam/molex/molex-dot-com/en_us/pdf/solution-guides/987652-6221.pdf)
- [POWER-Z KM003C](https://www.power-z.com/products/chargerlab-power-z-km003c)、[ESP32-S3-DevKitC-1 订货变体](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/index.html)

资料核对只证明候选合理，不证明到货批次、实物针序、机械装配或整机效果通过。
