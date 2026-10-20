# DualCam：iPhone 双摄相机（GitHub 云端编译版）

同时使用两颗摄像头拍照、录像：画中画 / 上下分屏，可选同时保存两路原片。
不需要 Mac：源码传到 GitHub，GitHub 的 Mac 服务器自动编译，把 `DualCam.ipa` 发布到 Releases，你下载后装到 iPhone。

## 一、上传到 GitHub（只做一次）
1. 登录 [github.com](https://github.com)，右上角 **+ → New repository**，名字随便取（如 `dualcam`），选 **Public**（公开仓库的 Actions 免费），点 Create。
2. 在新仓库页面点 **uploading an existing file**，把本压缩包解压后的**所有内容**（`DualCam` 文件夹、`project.yml`、`.gitignore`、`README.md`，以及 `.github` 文件夹）拖进去，点 **Commit changes**。
   - 如果拖完发现没有 `.github` 文件夹（Mac 的 Finder 默认隐藏以点开头的文件夹，拖不上去）：回到仓库，点 **Add file → Create new file**，文件名输入 `.github/workflows/build.yml`（输入斜杠会自动建文件夹），把解压出来的同名文件内容粘贴进去，再提交。
3. 提交后点仓库顶部的 **Actions** 标签，会看到 **Build IPA** 正在运行，等约 5～10 分钟变成绿色对勾。
   - 没有自动开始：点左边 **Build IPA → Run workflow**。

## 二、下载 IPA
仓库首页右侧 **Releases** → 最新的 `DualCam build-N` → 下载 **DualCam.ipa**。
（以后每次你修改文件并提交到 main，都会自动再编译并发布一个新 Release。）

## 三、装到 iPhone（Sideloadly）
这个 IPA 没有签名，需要用你自己的 Apple ID 签名后安装：
1. 电脑上安装 [Sideloadly](https://sideloadly.io)，按它官网提示装好依赖（Windows 需要 iTunes）。
2. iPhone 用数据线连电脑，点「信任此电脑」。
3. 打开 Sideloadly，把 `DualCam.ipa` 拖进去，填你的 Apple ID，点 **Start**。
4. 手机上：**设置 → 通用 → VPN 与设备管理** → 信任你的 Apple ID 证书。
5. 手机上：**设置 → 隐私与安全性 → 开发者模式** → 打开并重启。
6. 打开 DualCam，允许相机、麦克风、相册权限。

注意：免费 Apple ID 签名的 App **每 7 天会过期**，到期后重新用 Sideloadly 装一次即可（数据不丢）。Sideloadly 也支持自动续签，具体看它的说明。

## 四、App 怎么用
**界面**：整体是 iOS 26 的 Liquid Glass（动态玻璃）风格，按钮和面板是半透明玻璃，按下有流动反馈；iOS 26 以下自动回退成毛玻璃。预览显示的就是最终合成画面，**滤镜、小窗位置、画幅都是所见即所得**。

- **顶部**：闪光灯 / 定时器（关 → 3 秒 → 10 秒）/ 布局切换（画中画 ↔ 上下分屏）；右侧是镜头组合（`前+后`、`广+超广`、`广+长焦`，点一下循环切换）；中间显示输出分辨率和帧率，录像时变成计时。
- **小窗（画中画）**：
  - 手指拖动小窗到任意位置，松手自动吸附到边缘 / 中线（可关）
  - 双指在小窗上捏合缩放，或拖小窗右下角的小把手缩放
  - 点一下小窗：互换主 / 副画面
  - 工具面板「小窗」页：大小、形状（圆角 / 圆形）、比例（3:4 / 1:1 / 4:3 / 9:16）、圆角、边框、透明度、复位位置
  - 上下分屏时，拖动中间分割线（或面板里的滑杆）调整上下比例
- **滤镜**：工具面板「滤镜」页，12 个实时滤镜（鲜艳、暖阳、冷调、清新、电影、胶片、复古、褪色、铬黄、黑白、黑金），缩略图用当前画面实时生成，可调强度。滤镜作用在合成后的照片 / 视频上，「原片」不加滤镜。
- **参数**：工具面板「参数」页：变焦、曝光补偿、手动 ISO / 快门、白平衡（含色温 + 色调）、手动对焦、锁定对焦 / 曝光。
- **设置**：工具面板「设置」页：
  - 画幅：9:16 / 3:4 / 1:1
  - 分辨率：720p / 1080p / 最高（最高 4K，不会超过摄像头实际像素，不做无意义的放大）
  - 帧率：30 / 60 fps（60 帧更吃性能，默认 30）
  - 保存两路原片、弱光增亮、视频防抖、前置镜像、三分参考线
- **对焦 / 曝光**：点按画面对焦并测光（点小窗就对小窗镜头对焦）；画面内容明显变化后自动回到连续对焦；点按后上下滑动实时调曝光补偿；双指捏合变焦。
- **变焦**：快门上方的倍率按钮（超广角显示 0.5x，长焦按实际倍率），主 / 副镜头各自记住自己的变焦。
- **拍照 / 录像**：底部「拍照 / 录像」切换（点击或左右滑动），中间快门；设了定时器会先倒数，再点一下取消。
- 作品保存在系统「照片」App：拍照是高质量 JPEG，录像是 HEVC（H.265）。录像时可随时切布局、拖小窗、换滤镜，合成视频实时跟随。
- 只支持竖屏。

## 五、常见问题
- **Actions 变红色叉**：点进失败的运行，把报错那几行复制给我，我来改。
- **提示不支持多摄像头**：机型需 iPhone XS / XR 及以上，模拟器不行。
- **装好后一打开就闪退**：确认已打开「开发者模式」并信任了证书。
- **想改 App 名字或图标**：改 `project.yml` 里的 `CFBundleDisplayName`；图标可以以后再加。

## 文件说明
- `DualCameraManager.swift`：相机会话、参数控制、渲染流水线、拍照 / 录像
- `Compositor.swift`：画面合成（画中画 / 分屏 / 滤镜），预览、照片、视频共用
- `Filters.swift`：12 个实时滤镜
- `Settings.swift`：各种枚举和小窗配置（位置、大小、形状……）
- `ContentView.swift`：主界面和手势
- `ControlViews.swift`：工具面板（小窗 / 滤镜 / 参数 / 设置）
- `Glass.swift`：Liquid Glass 封装（iOS 26+ 用系统玻璃，更早的系统回退成毛玻璃）
- `PreviewView.swift`：把合成画面显示到 SwiftUI
- `MovieWriter.swift`：视频写入（HEVC）
- `project.yml`：XcodeGen 工程描述（含 3 个权限说明，仅竖屏）
- `.github/workflows/build.yml`：云端编译并发布 Release 的流程（macos-26 / Xcode 26）
- `LayerHost.swift`：旧版预览用的文件，现在已经用不到，可以删掉（留着也不影响编译）


## 相机增强分支（2026-10）

分支 `feature/live-photo-gallery-camera-ux` 增加：
- 相机模式增加「实况」：录制约 3 秒合成画面，尝试生成 Live Photo 配对静态图和 MOV，使用 PhotoKit 保存。
- 增加系统照片图库入口：缩略图按需加载；可查看照片、识别视频，并从视频菜单选择「转换为实况照片」。
- 新增 `LivePhotoConverter.swift`，负责提取静帧、写入 content identifier / still-image-time 元数据并保存配对资源。
- 新增 `MediaGalleryView.swift`，需要照片读取权限；`project.yml` 已补充权限用途说明。

注意：实况照片元数据与 PhotoKit 导入行为受 iOS 版本影响，必须在真实 iPhone 上验证。当前环境未运行 Xcode 真机测试；如果系统拒绝配对资源，会显示转换错误，拍摄模式会回退保存普通视频，不会把普通视频伪装成 Live Photo。
