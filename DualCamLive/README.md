# DualCamLive — 原生 iOS 双摄相机

SwiftUI + AVFoundation MultiCam + Metal compositor + AVAssetWriter，独立于仓库中旧版 DualCam 工程。

## 构建

在 Mac 上安装 Xcode 26 与 XcodeGen：

```sh
brew install xcodegen
cd DualCamLive
xcodegen generate
open DualCamLive.xcodeproj
```

在 Xcode 中选择自己的开发团队、连接真实 iPhone 并授予相机、麦克风、照片图库权限。GitHub 云端编译不能替代真机验证。

## 当前实现范围

- 手动 MultiCam input/output connection、两路 YUV 样本、Metal 合成、前置镜像、PiP 圆角与上下分屏。
- 合成帧用于预览、JPEG 照片和 AVAssetWriter 视频；支持可选麦克风 AAC 音轨。
- 12 个合成后 Core Image 滤镜与强度；使用轻量实色控件，主动避免 Liquid Glass / Material 模糊以降低 UI 合成开销。
- PhotoKit 保存合成照片与视频。
- 实况照片（Live Photo）仍未完成：必须生成配对静态图/MOV、正确 content identifier、StillImageTime 与 Apple MakerNote，并用 PhotoKit 验证导入。不会将普通视频冒充 Live Photo。
- 两路原片分别保存、弱光增强、实时防抖、完整手动 ISO/快门/白平衡控制、真正 4K 合成输出仍需后续接入。
- 具体双摄格式、60fps、硬件压力与长时音画同步需在目标 iPhone 上测试。

## 上游来源

MultiCam session、Metal compositor、Metal shader 和 AVAssetWriter 实现参考 MIT 许可的 https://github.com/RomanSlack/dual_cameras 。请阅读仓库中的 THIRD_PARTY_NOTICES.md。


## 性能模式

工具栏使用深色实色底与细描边，不调用 `glassEffect` 或 `.ultraThinMaterial`。这能减少界面模糊效果的额外合成，但需在真实设备上单独测量 GPU、帧率与温度变化。
