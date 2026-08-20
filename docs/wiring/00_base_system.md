# Base `00_SYSTEM` 页任务清单

> 本页是系统框图与跨页契约页，不承载器件逐脚接线。编号用于分工和验收，不代表导线。

| 编号 | 任务 | 状态 | 完成证据 |
|---:|---|---|---|
| 1 | 维护唯一电源链 `VBUS_RAW → VBUS_PD → VBUS_BUCK_IN → 5V_SYS` | A | 与 01 网络成员一致 |
| 2 | 维护 `BASE_3V3/AUDIO_3V3A/HEAD_5V/MOTOR_5V` 四分支 | A | 不新增模糊 `VCC/5V` 网名 |
| 3 | 标出 Base、Head、Motion 三个实时域和故障隔离 | A | 与 10 第 4 节一致 |
| 4 | 标出 Head 30Pin FFC、Motion UART、音频 I²S/I²C 接口 | A | 与各页清单一致 |
| 5 | 标出 `H-IO-001/H-MIC-001/H-FFC-001/H-MOT-001/H-ENC-001` | A | Gate 不被标成已关闭 |

停止条件：本页不得放入芯片外围，不得以框图连线代替其他页的真实网络连接。
