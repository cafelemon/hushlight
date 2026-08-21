# Head `01-DISPLAY-TOUCH` 任务清单

> 当前页为空白。在线资料只能确认目标功能，不能替代实际 IPS/触控 FPC 通断与时序测试。

| 编号 | 任务 | 状态 | 关闭证据 |
|---:|---|---|---|
| 1 | 复核 2.4 英寸 320×240 IPS/电容触控完整型号与版本 | GATE | datasheet、实物标签、RFQ 一致 |
| 2 | 复核显示 controller、触控 controller 及 I²C 地址 | GATE | datasheet + 上电扫描 |
| 3 | 复核显示/触控供电、电流峰值、背光和掉电行为 | GATE | 台架波形 |
| 4 | 冻结 Head-S3 显示总线 GPIO 与 DMA/PSRAM 分配 | GATE | 与摄像头、启动脚和 PSRAM 无冲突；20fps 实测 |
| 5 | 冻结 `HEAD_IRQ_N/HEAD_READY/HEAD_RESET_N/HEAD_BOOT_N` | GATE | GPIO 电平和默认态 |
| 6 | 选择并放置模组连接器/插座 | GATE | 制造商料号、Pin 1、封装、3D |
| 7 | 放置 Head 入口 `100µF+1µF+100nF` | 待 3 关闭 | 额定电压、DC Bias、浪涌符合实测 |

缺件不提前放：模组座与入口 bulk 的封装均受真实模组和可用空间影响。
