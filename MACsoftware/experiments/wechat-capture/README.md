# 微信窗口捕获独立实验

只读、无网络、无发送、无密钥/数据库访问，不改生产截图链路。按用户专项报告建立，编译源码不等于实机通过。

## 编译

```sh
xcrun swiftc -parse-as-library MACsoftware/experiments/wechat-capture/CaptureTest.swift -o /tmp/orbit-wechat-capture-matrix
```

## 前置条件

本人在文件传输助手预置 `ORBIT_CAPTURE_TEST_20261024`，只显示无敏感样本。独立窗口通常应有其标题；本机当前仅枚举到“微信”主窗和“设置”，因此实际矩阵按用户已准备的主窗记录，未假称找到了独立文件传输助手窗口。多个同名窗或目标变化时拒绝。

软件不弹出权限申请。缺少捕获/AX权限输出blocked并停止；不能通过自动重置TCC或改签绕过。原型进程具有权限不证明App各项权限，也不证明其他工具捕获实现。

```sh
/tmp/orbit-wechat-capture-matrix --mode I
/tmp/orbit-wechat-capture-matrix --mode A --target 微信
/tmp/orbit-wechat-capture-matrix --mode B --target 微信
/tmp/orbit-wechat-capture-matrix --mode C --target 微信
/tmp/orbit-wechat-capture-matrix --mode D --target 微信
/tmp/orbit-wechat-capture-matrix --mode F --target 微信
```

E仅在用户明确同意显示器对照并收起敏感内容后使用：

```sh
/tmp/orbit-wechat-capture-matrix --mode E --target 微信 --allow-display
```

E使用显示器级过滤，但sourceRect仍裁在目标窗几何区域，不能排除其他覆盖其上的可见内容；不会保存或输出图像、OCR正文。实验授权仅用于此对照，不扩展生产截图范围。

G设置页对照：`--mode A --target 设置`。其他普通应用仅允许计算器Bundle ID，由用户显示无敏感数字后指定真实标题；不凭空选择其他应用窗口。最多5次重复，每次重新绑定目标。外层运行脚本应加进程超时，防系统API异步调用卡住；日志为JSONL，错误只含固定枚举或域/代码。

## 输出与判定

输出环境、ID/PID/尺寸、方法、耗时、接收帧统计、预置串是否匹配。I只输出匹配布尔、计数、几何及PID，不输出其他窗口标题；F有限遍历仅匹配固定测试串，不输出消息文本。D包含warm/post阶段与PTS/displayTime元数据，以防把过滤器没更新或旧帧当成功。像素variance与OCR行数不是聊天成功证据。

成功需固定测试串可读，并由本人确认对应正确测试内容；初步成功再做多次冷启动/连续采样/窗口切换。当前不保存截图，也不把OCR文本发给模型。`screenshots/`仅为报告目录结构占位，未产生真实聊天图像。

## 已确认不共享的窗口

元数据I发现`sharing_state=0`时，A–E/D2捕获会明确返回`windowSharingRestricted`，不尝试穿透；这项保护在本机诊断确认后加入。模式I仍可读取公开元数据；F只检查AX测试串，不产生鼠标/键盘操作。完整结论参见本地排障手册。D2为设置预热的历史对照变体，语法`--mode D2 --target 微信 --settings-title 设置`，不能覆盖共享限制保护。
