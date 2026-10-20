# DualCam 双摄相机

一款基于 **SwiftUI + AVFoundation `AVCaptureMultiCamSession`** 的 iPhone 双摄相机项目。当前仓库提供可在 Xcode 中打开的原生 iOS 工程和第一阶段 MVP：双摄预览、画中画 / 上下分屏、主副画面互换、画中画拖动吸附、倒计时拍照，以及合成照片保存到系统照片图库。

> 当前版本：`0.1.0 MVP`。原始产品设想见 [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md)。README 中会区分已实现功能与后续规划，不把尚未完成的录像、滤镜和手动相机参数描述为已可用。

## 当前功能

- 基于 `AVCaptureMultiCamSession` 同时启动前置与后置广角摄像头。
- 实时双路预览，支持画中画 / 上下分屏。
- 点击副画面切换主、副画面；画中画可拖动并在松手时吸附到左右边缘。
- 关闭 / 3 秒 / 10 秒拍照倒计时。
- 尝试使用后置摄像头补光灯（设备支持时）。
- 双路拍照后按当前布局合成为一张竖幅照片，并请求写入系统「照片」图库。
- 相机不可用、系统权限未授予或设备不支持双摄时提供错误提示。

## 开发环境

- macOS + Xcode 15 或更新版本
- iOS 17.0+
- 支持 `AVCaptureMultiCamSession` 的真机 iPhone（模拟器通常无法验证真实双摄能力）

## 运行

1. 下载 / 克隆仓库，在 Xcode 中打开 `DualCam.xcodeproj`。
2. 选择 `DualCam` Scheme 和一台支持双摄的 iPhone。
3. 在签名设置中选择自己的 Apple Developer Team；首次运行时允许相机与照片添加权限。
4. 在真机上测试双摄预览与拍照。双摄能力和同时输出限制会因设备型号而异。

## GitHub 上传

在 GitHub 创建一个名为 `DualCam` 的空仓库，然后在本项目根目录执行：

```bash
git init
git add .
git commit -m "Initial DualCam iOS MVP"
git branch -M main
git remote add origin https://github.com/<你的用户名>/DualCam.git
git push -u origin main
```

将 `<你的用户名>` 替换为你的 GitHub 用户名。如果创建仓库时已自动生成 README、LICENSE 或 `.gitignore`，建议创建时不要勾选这些初始化文件，以免第一次推送出现历史冲突。

## 当前限制 / 下一阶段

以下功能属于原始产品规划，尚未在此 MVP 中完成：合成视频录制与 HEVC 导出、完整的实时滤镜组、手动 ISO / 快门 / 白平衡 / 对焦、变焦控制、可调画中画尺寸与形状、画幅 / 分辨率 / 帧率设置、实况照片、两路原片保存和完整辅助网格。

`AVCaptureMultiCamSession` 的硬件预算受到机型限制；即使系统允许两路预览，也不保证该机型允许两路 `AVCapturePhotoOutput` 同时工作。当前代码会在配置时检查相关连接，并在无法启用双路拍照输出时显示错误，而不是保证所有机型都可用。

## 许可

本项目按 MIT License 发布，详情见 [`LICENSE`](LICENSE)。
