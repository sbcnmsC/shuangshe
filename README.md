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
- **摄像头**：`前 + 后`、`广角 + 超广角`（超广角需 iPhone 11 及以上）或 `广角 + 长焦`（长焦需 iPhone 7 Plus / 11 Pro 及以上），点右上角镜头按钮循环切换
- **布局**：`画中画`（点小窗互换）或 `上下分屏`，点左上角按钮切换
- **类型**：`拍照` / `录像`，底部模式栏点击或左右滑动切换；点中间快门，录像再点一次结束
- **存原片 / 仅合成**：开「存原片」时，除合成的一份外，还会单独保存两颗摄像头各自的画面
- **对焦 / 曝光**：点按画面任意位置对焦并测光；点按后上下滑动可调曝光补偿（EV）；按住「锁定对焦/曝光」可固定当前对焦与曝光，防止拍摄中漂移
- **变焦**：快门上方点 `1x / 2x / 5x` 快速切换，或双指在画面上捏合缩放
- **闪光灯**：顶部闪电按钮，拍照时会自动短暂打光
- **参数面板**：点快门右侧「参数」按钮打开，可调节：变焦、曝光补偿、手动 ISO / 快门、白平衡（自动 / 日光 / 多云 / 白炽灯 / 荧光灯 / 自定义色温）
- 作品保存在系统「照片」App；录像时可随时切布局、换画面，合成视频实时跟随

## 五、常见问题
- **Actions 变红色叉**：点进失败的运行，把报错那几行复制给我，我来改。
- **提示不支持多摄像头**：机型需 iPhone XS / XR 及以上，模拟器不行。
- **装好后一打开就闪退**：确认已打开「开发者模式」并信任了证书。
- **想改 App 名字或图标**：改 `project.yml` 里的 `CFBundleDisplayName`；图标可以以后再加。

## 文件说明
- `DualCam/*.swift`：App 源码（界面、相机会话、画面合成、视频写入）
- `project.yml`：XcodeGen 工程描述（含 3 个权限说明），云端会据此生成 Xcode 工程
- `.github/workflows/build.yml`：云端编译并发布 Release 的流程
- `ControlViews.swift`：参数面板（变焦、曝光、白平衡、AE/AF 锁定）
