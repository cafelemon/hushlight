# Base `04-AUDIO-OUT` 接线清单

> 当前器件：`U3=ES8311`、`U2=NS4150`（正式基线要求 NS4150B，须先核对器件属性/变体）、`J9` 扬声器座。数字/供电网络可执行；模拟增益和 AEC 分支等待音频 Gate。

## A：本轮可执行

| 编号 | 源引脚 | 目标网络/引脚 | 说明 | 执行/复核 |
|---:|---|---|---|---|
| 1 | `U3-PVDD` | `AUDIO_3V3A` | 数字 I/O 电源 | |
| 2 | `U3-DVDD` | `AUDIO_3V3A` | 数字内核电源 | |
| 3 | `U3-AVDD` | `AUDIO_3V3A` | 模拟电源 | |
| 4 | `U3-DGND` | `GND` | 数字地 | |
| 5 | `U3-AGND` | `GND` | 模拟地，按 codec 推荐单点回流 | |
| 6 | `U3-CCLK` | `SYS_I2C_SCL` | I²C 时钟 | |
| 7 | `U3-CDATA` | `SYS_I2C_SDA` | I²C 数据 | |
| 8 | `U3-MCLK` | `I2S_MCLK` | Base GPIO4 | |
| 9 | `U3-SCLK/DMIC_SCL` | `I2S_BCLK` | Base GPIO5 | |
| 10 | `U3-LRCK` | `I2S_LRCK` | Base GPIO6 | |
| 11 | `U3-DSDIN` | `DAC_DSDIN` | Base GPIO8 输出 | |
| 12 | `U2-VCC` | `5V_SYS` | 功放电源 | |
| 13 | `C22-1` | `5V_SYS` | 10µF 功放近端 bulk | |
| 14 | `C23-1` | `5V_SYS` | 100nF 功放高频去耦 | |
| 15 | `C22-2` | `GND` | bulk 回流 | |
| 16 | `C23-2` | `GND` | 高频回流 | |
| 17 | `C24-正` | `5V_SYS` | 220µF 功放 bulk | |
| 18 | `C24-负` | `GND` | 注意极性 | |
| 19 | `U2-GND` | `GND` | 功放地 | |
| 20 | `U2-CTRL` | `PA_ENABLE` | Base GPIO48 控制 | |
| 21 | `R10-1` | `PA_ENABLE` | 10kΩ 默认下拉信号端 | |
| 22 | `R10-2` | `GND` | MCU 复位时关闭功放 | |

## 框外新增器件

| 功能 | 数量 | 冻结型号 | 放置状态 | 后续连接 |
|---|---:|---|---|---|
| ES8311 模拟参考电容 | 3 | `C66–C68`，Samsung `CL10B105KP8NNNC`，1µF/10V，0603，LCSC `C95843` | 2026-08-20 已放 04 页图框外并保存，未接线 | 分别服务 `VMID`、`ADCVREF`、`DACVREF` 到 AGND |

现有 `C18/C20=1µF` 预留为 ES8311 OUTP/OUTN 到功放差分输入的两只隔直电容；新增 3 只只承担 codec 内部参考去耦，避免混用。

## Gate

- 先把在线器件 `U2=NS4150` 与正式 `NS4150B` 的引脚、封装、制造商编号逐项核对；不一致时替换器件，不直接改显示名称。
- `U3.CE` 对应 I²C 地址必须以 ES8311 数据手册和首板扫描冻结，当前不得猜接。
- `U3.OUTP/OUTN → C18/C20 → U2.IN+/IN−`、AEC 分支和 R11 调整位需与 Korvo-2 推荐 AEC 拓扑一起评审后发布。
- `U2.OUT+/OUT− → J9` 为 BTL 差分输出，两端均不得接地；扬声器实际 4Ω/3W 型号和连接器针序冻结后执行。

## 资料依据

- [Everest ES8311 官方 product brief/datasheet](https://www.everest-semi.com/pdf/ES8311%20PB.pdf)
- [Espressif ESP32-S3-Korvo-2 V3.1 官方参考设计说明](https://docs.espressif.com/projects/esp-adf/en/latest/design-guide/dev-boards/user-guide-esp32-s3-korvo-2.html)
- [Espressif ESP32-S3-Korvo-2 官方原理图](https://dl.espressif.com/dl/schematics/SCH_ESP32-S3-KORVO-2_V3_0_20210918.pdf)
