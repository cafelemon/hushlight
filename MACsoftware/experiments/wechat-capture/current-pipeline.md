# 当前捕获链路调查

本机核对：macOS 26.7.1（25G241）、arm64、微信4.1.13。Gist作者报告的15.6.1/4.1.15与此不同，不能直接搬用其验收结论。

## Codex桌面工具

调用为 `cua.getApp("com.tencent.xinWeChat")` → `getAXState/getScreenshot/getAXStateAndScreenshot` → 工具显示图像。此工具后端不属于本仓库，具体捕获API、编码、缓存与过滤器实现没有源码证据，不能推定其使用哪一种系统截图API。已观察：主窗与独立单聊正文白屏；独立单聊标题正确；设置页图像可读。AX主窗/独立窗仅暴露窗口和菜单，没有消息控件；登录提示可读。不能据此断言微信主动限制共享或工具存在某个具体bug。

## Orbit App

`WindowVisionView`显式预览 → `WindowVisionModel.capturePreview` → `NativeWindowVisionBackend.capturePreview` → `NativeWindowVisionSurface.capture` → `SCScreenshotManager.captureImage`。

来源：`Sources/HushlightMac/Services/WindowVisionBackend.swift`。枚举`SCShareableContent.current`，按目标Bundle ID、PID、窗口ID、可见性、layer0、尺寸识别；捕获前后再次核对。`SCContentFilter(desktopIndependentWindow:)`，配置窗口大小、关闭cursor/audio/childWindows，忽略单窗阴影。不存在整屏兜底。

返回`CGImage`直接封装为内存预览，不经过PNG/JPEG落盘或网络。Canvas只是等比例显示；框选归一坐标映射到图像pixelRect后裁切，再由Vision OCR，结果转换为左上角归一坐标。AI定位另由明确点击触发有界文字分析，本专项原型不调用它、不向模型上传图片或OCR。清空/离页/暂停释放预览；没有持久截图缓存。

现有尺寸、权限、身份、裁切等源码检查不能证明图像内容可读；像素颜色、透明度、色彩空间与buffer时序须由A–G实验对照。实验完成前不修改生产截图链路。
