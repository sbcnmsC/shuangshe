# DualCam — 原生 iOS 双摄相机工程

这是使用 **SwiftUI + AVFoundation + Core Image + AVAssetWriter + Photos** 构建的原生相机项目，默认支持 iOS 17 及以上，Liquid Glass 效果在 iOS 26 上启用，旧系统回退为 `.ultraThinMaterial` 毛玻璃。

## 打开工程

1. 将 `DualCam.zip` 解压到 Mac。
2. 使用 **Xcode 26 或更新版本**打开 `DualCam.xcodeproj`。
3. 在 Signing & Capabilities 中选择自己的 Apple 开发团队；如有需要更改 Bundle Identifier（默认 `com.example.DualCam`）。
4. 连接真实 iPhone，选择设备并运行。相机与双摄功能不能仅依靠 iOS 模拟器验证。
5. 首次启动时允许相机、麦克风和照片添加权限。

## 已连接的主要能力

- 自动请求相机/麦克风权限；多摄初始化失败时回退到单摄，避免因设备不支持组合而直接打不开。
- 查询系统支持的 `supportedMultiCamDeviceSets`，选择兼容的前后摄像头组合，并使用 `AVCaptureDataOutputSynchronizer` 对齐双路视频帧。
- 实时合成预览，包含画中画/上下分屏、拖动小窗、缩放小窗、圆角/圆形、比例、边框、透明度、布局交换、三分参考线。
- 12 个滤镜选项（含原片）和强度控制；滤镜作用于合成结果，另外可选择保存未加滤镜的两路镜头原片。
- 曝光补偿、变焦、ISO/快门、色温/色调、手动对焦与锁定操作（具体范围以设备支持为准）。
- 定时拍摄/录像、JPEG 写入系统照片图库、HEVC 视频写入与图库保存；可选麦克风音频轨道。
- iOS 26 使用系统玻璃材质，较旧版本使用毛玻璃回退。

## 真实设备限制与当前版本边界

- **双摄并非所有 iPhone 都支持所有组合。** 工程使用系统提供的多摄组合能力做检测；没有兼容组合时会使用单摄模式。
- 录像中的最终画面来自同步的视频数据流，并用 Core Image 实时合成后写入 HEVC。为了保证连续性，本版本的静态照片也来自当前合成帧，并非分别触发两颗传感器的满像素静态照片流程。因此照片分辨率取决于当前视频流，不等同于系统原生相机的最高静态照片像素。
- “最高”模式会根据当前视频流的长边限制合成画布，**不会把低分辨率输入强行放大成 4K**。当前版本不主动把每一路传感器切到 4K 格式，因为双摄 4K 组合容易超过不同设备的硬件开销预算；具体输出以顶部实际尺寸为准。
- 双摄 60 fps、持续 4K、弱光增亮、物理镜头组合都受到具体机型、所选格式和系统压力约束。若出现过热或掉帧，建议选择 1080p / 30 fps。
- “定时器”控制拍摄前倒数；录像开始后暂不支持中途切换物理镜头组合，以避免会话重建中断文件。
- **实况照片（Live Photo）及“视频转实况”尚未接入。** 当前拍照会保存合成 JPEG，录像保存 HEVC 视频；要生成系统相册可识别的 Live Photo，还需补充成对的静态图/短视频资源与配对元数据。
- 顶部闪光灯控制在当前视频流架构中使用设备支持时的持续补光灯（Torch），不是照片输出管线中的独立闪光灯曝光。
- 当前帧合成与写入是可运行的实现基础，但尚未经过 Xcode 真机编译、机型矩阵和长时间过热测试。

## 代码结构

```text
DualCam/
├── DualCam.xcodeproj/
├── DualCam/
│   ├── DualCamApp.swift
│   ├── ContentView.swift
│   ├── Info.plist
│   ├── Camera/CameraManager.swift
│   ├── Models/CameraSettings.swift
│   └── Views/
│       ├── CameraToolsPanel.swift
│       └── GlassStyle.swift
└── README.md
```

## 重点排查项

如果 Xcode 报错，请先确认使用 Xcode 26 / iOS 26 SDK。若真机提示“无法添加摄像头输入”，这通常是该机型的双摄组合或硬件资源不满足；可在调试时查看 `AVCaptureMultiCamSession.hardwareCost` 和 `systemPressureCost`，必要时降低分辨率和帧率。照片不保存时请检查系统设置里 DualCam 的照片添加权限。
