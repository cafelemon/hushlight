# Base `03-AUDIO-IN` 接线清单

> 当前器件：`U4=ES7210`、`U14/U15=IM73A135V01XTSA1`、`U16=TPS7A2028PDBVR`。供电/数字网络可执行；模拟输入和物理静音链等待 `H-MIC-001`。

## A：本轮可执行

| 编号 | 源引脚 | 目标网络/引脚 | 说明 | 执行/复核 |
|---:|---|---|---|---|
| 1 | `U4-VDDP` | `AUDIO_3V3A` | 数字 I/O 电源 | |
| 2 | `U4-VDDD` | `AUDIO_3V3A` | 数字内核电源 | |
| 3 | `U4-VDDA` | `AUDIO_3V3A` | ADC 模拟电源 | |
| 4 | `U4-VDDM` | `AUDIO_3V3A` | 麦克风模拟电源域 | |
| 5 | `U4-GNDD` | `GND` | 数字地 | |
| 6 | `U4-GNDA` | `GND` | 模拟地；布局按 ADC 推荐单点回流 | |
| 7 | `U4-CDATA` | `SYS_I2C_SDA` | I²C 数据 | |
| 8 | `U4-CCLK` | `SYS_I2C_SCL` | I²C 时钟 | |
| 9 | `U4-AD0` | `GND` | 地址位 0 | |
| 10 | `U4-AD1` | `GND` | 地址位 0；7-bit 候选 `0x40` | |
| 11 | `U4-MCLK` | `I2S_MCLK` | Base GPIO4 输出 | |
| 12 | `U4-SCLK` | `I2S_BCLK` | Base GPIO5 输出，U4 从模式 | |
| 13 | `U4-LRCK` | `I2S_LRCK` | Base GPIO6 输出，U4 从模式 | |
| 14 | `U4-SDOUT1/TDMOUT` | `ADC_SDOUT` | 到 Base GPIO7 | |
| 15 | `U16-IN` | `AUDIO_3V3A` | 麦克风 LDO 输入 | |
| 16 | `C52-1` | `AUDIO_3V3A` | U16 输入 2.2µF；本版冻结 C52=输入 | |
| 17 | `C52-2` | `GND` | 输入回流 | |
| 18 | `U16-GND` | `GND` | LDO 地 | |
| 19 | `U16-EN` | `AUDIO_3V3A` | LDO 常开；物理开关切断其输出后的实际麦供电 | |
| 20 | `U16-OUT` | `MIC_2V8_LDO` | 静音开关前电源 | |
| 21 | `C53-1` | `MIC_2V8_LDO` | U16 输出 2.2µF；本版冻结 C53=输出 | |
| 22 | `C53-2` | `GND` | 输出回流 | |

## 框外新增器件

| 功能 | 数量 | 冻结型号 | 放置状态 | 后续连接 |
|---|---:|---|---|---|
| 双麦差分 AC 耦合 | 4 | `C62–C65`，Samsung `CL10B105KP8NNNC`，1µF/10V，0603，LCSC `C95843` | 2026-08-20 已放 03 页图框外并保存，未接线 | `MIC1 OUT± → 1µF → U4 MIC1P/N`；`MIC2 OUT± → 1µF → U4 MIC2P/N` |

选择依据：IM73A135 为差分模拟输出；ES7210 典型应用和 Espressif Korvo-2 参考图在每个差分输入端使用 1µF 耦合。

## Gate

- `MIC_2V8_LDO → 3PDT 锁定开关 → MIC_2V8 → U14/U15.VDD`，必须先冻结真实 3PDT 型号、触点真值表和机构开孔。
- U14/U15 的 OUT± 到 U4 的耦合电容已可放置，但 `H-MIC-001` 关闭前不接线。
- U4 的 REFP/REFQ/REFQM、MICBIAS 和 AEC 参考通道按 ES7210 典型应用逐脚冻结后另增 A 表；不得为消除 ERC 接地。
- `SDOUT2/TDMIN`、`INT`、`DMIC_CLK` 和未用 MIC3/4 脚按最终模式明确 NC/DNP。

## 资料依据

- [Infineon IM73A135V01 官方 datasheet](https://www.infineon.com/assets/row/public/documents/24/49/infineon-im73a135-datasheet-en.pdf)
- [Everest ES7210 Rev 21.0 datasheet](https://files.waveshare.com/wiki/common/ES7210_DS.pdf)
- [Espressif ESP32-S3-Korvo-2 V3.1 官方参考设计说明](https://docs.espressif.com/projects/esp-adf/en/latest/design-guide/dev-boards/user-guide-esp32-s3-korvo-2.html)
