# Sony Camera Control

面向 Sony Camera Remote SDK 支持机型的桌面相机控制软件，提供实时取景、参数调整、照片直传、原生连拍和手动调焦。使用 **Camera Remote SDK 2.02**：Windows / Linux 版采用 Qt 与 C++，macOS 版采用 SwiftUI。

当前发行版本：**Windows / Linux v1.3.0**，**macOS v1.2.0**。已实机验证的相机为 **ILX-LR1**；其他机型的支持范围以 [Sony 官方 SDK 列表](https://support.d-imaging.sony.co.jp/app/sdk/en/index.html)为准，功能可用性取决于相机、固件、镜头及当前模式。

## 下载

- **Windows 11 x64**：[下载 ZIP](https://github.com/Kiriusss/Sony-Camera-Control/releases/download/v1.3.0/SonyCameraControl-1.3.0-windows-x64.zip)，解压运行。
- **Debian / KDE x86_64**：[下载 DEB](https://github.com/Kiriusss/Sony-Camera-Control/releases/download/v1.3.0/sony-camera-control_1.3.0_amd64.deb)，推荐使用，可自动安装依赖、桌面入口和 USB 权限规则。
- **Linux x86_64 目录包**：[下载 tar.gz](https://github.com/Kiriusss/Sony-Camera-Control/releases/download/v1.3.0/SonyCameraControl-1.3.0-linux-x64.tar.gz)，需自行准备系统依赖和 USB 权限。
- **macOS Apple silicon**：[下载 v1.2.0 ZIP](https://github.com/Kiriusss/Sony-Camera-Control/releases/download/v1.2.0/Sony-Camera-Control-macOS-arm64-v1.2.0.zip)。本轮未重新构建 macOS 版本。

Windows / Linux 发行包已包含 Python、Qt 和 Sony SDK 运行库，无需另外安装 Python 或下载 SDK 开发包。请保留完整应用目录，包括 `_internal` 和 `CrAdapter`。

[v1.3.0 发布说明](https://github.com/Kiriusss/Sony-Camera-Control/releases/tag/v1.3.0)包含各安装包的 `.sha256` 校验文件及[总校验清单](https://github.com/Kiriusss/Sony-Camera-Control/releases/download/v1.3.0/SHA256SUMS-v1.3.0.txt)。

**验证范围：** Windows 已完成 LR1 实机测试；Linux 包在 Debian 12 构建，完成安装和 WSLg X11 / Wayland 启动检查。真实 KDE 会话、Linux USB 拍摄及 Debian 13 尚未实测。当前 Windows / Linux 仅提供 x86_64 安装包，尚无 Linux ARM64、Android 或鸿蒙安装包。

## 功能

- 搜索、连接和断开相机，支持 USB 及相机提供的网络连接方式、网络认证与实时取景。
- 读取曝光模式、快门、光圈、ISO、白平衡和照片格式，调整相机当前允许修改的参数。
- 单张拍摄并将原始照片文件直接保存到电脑；支持无卡拍摄的相机可不插存储卡使用。
- 原生连拍：读取相机可用档位，支持 0.5–10 秒自动停止及提前停止；每轮独立文件夹，RAW＋JPEG / HEIF 配对后按完整照片计数。
- 自动对焦，以及镜头支持的手动近远步进、指定焦位、实际位置回读和停止调焦。焦位数值不代表以米为单位的距离。
- 查看运行日志、下载状态和照片记录，选择保存目录，支持中文路径。
- 将电脑收到的实时取景录制为本地视频：Windows / Linux 为 **MJPEG AVI、5 fps、无音轨**；macOS 为 **H.264 MOV、无音轨**。这项功能不启动相机机内录像，画质和分辨率取决于 SDK 取景画面。

## 安装与首次连接

### Windows

1. 解压下载的 ZIP，保留整个 `SonyCameraControl` 文件夹。
2. 为相机供电开机，使用 USB 数据线连接电脑，并在相机上选择 **PC Remote（PC 遥控）**。
3. 首次 USB 连接需安装包内 Sony 驱动。在解压后的 `SonyCameraControl` 目录打开管理员 PowerShell，执行：

   ```powershell
   pnputil /add-driver .\drivers\srcameradriver.inf /install
   ```

4. 重新插拔 USB，运行 `SonyCameraControl.exe`，点击“搜索相机”，选择设备后点击“连接”。

驱动安装后，设备应显示为 `Sony Remote Control Camera`，类别为 `libusbK Usb Devices`。这会替换该相机的 MTP 驱动；需要恢复普通文件传输时，可在设备管理器中重新选择微软 MTP 驱动。当前验证目标为 Windows 11 x64，Windows 10 未实测。

### Debian / KDE

在下载目录执行：

```bash
sudo apt install ./sony-camera-control_1.3.0_amd64.deb
```

安装后重新插拔处于 PC Remote 模式的相机，在 KDE 应用菜单打开 **Sony 相机控制**，或以普通桌面用户运行：

```bash
sony-camera-control
```

DEB 包包含 udev 权限规则，允许活动的本地桌面会话访问 Sony 静态图像设备。应用无需以 root 身份运行。若其他相机控制或照片导入程序已占用设备，先退出这些程序，再搜索相机。

包内包含 Qt 的 X11 和 Wayland 插件。若 KDE Wayland 下出现显示问题，可在已安装 XWayland 的会话中尝试：

```bash
QT_QPA_PLATFORM=xcb sony-camera-control
```

Linux x86_64 包的最低 glibc 要求为 2.36。完整依赖、目录包说明及 ARM64 构建限制见 [Windows / Linux 桌面版说明](DESKTOP.md)。

### macOS

解压 v1.2.0 安装包，打开 `Sony Camera Control.app`。相机选择 PC Remote 模式；如系统询问 USB 配件连接权限，允许连接后点击“搜索”和“连接相机”。相机菜单设置、网络连接和 macOS 常见问题见 [macOS 使用说明](使用说明.md)。

### 拍摄与保存

连接后先确认实时取景与保存目录，再进行拍摄。软件会设置电脑直传，并启用相机支持的无卡释放选项。停止连拍后仍可能继续回传文件，请等待界面显示本轮下载完成。

- **Windows / Linux 默认目录**：用户主目录下的 `Pictures/Sony Captures`。
- **macOS 默认目录**：`~/Pictures/LR1 Captures`，沿用已有保存设置。

可在界面更改保存位置。拍摄或回传期间无法调整的选项，以及当前模式不支持的参数，会显示为不可用。连接超时时，检查其他遥控软件、照片导入程序，以及 macOS 的“预览”“图像捕捉”是否占用设备。

## 从源码构建

源码构建需要自行准备对应平台的 **Sony Camera Remote SDK 2.02**。仓库不包含 SDK 开发包、相机照片或本机日志。

### Windows / Linux

将对应平台的 SDK ZIP 放在仓库根目录：Windows 使用 `Win64`，Linux x86_64 使用 `Linux64PC`。构建脚本会选择并解包本地 SDK。

Windows 需要 Python 3.12 和 Visual Studio C++ Build Tools（x64 编译器及 Windows SDK），在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/build-windows.ps1
```

Debian 安装 [桌面版说明中的构建依赖](DESKTOP.md#重新构建)后执行：

```bash
bash Scripts/build-linux.sh
```

构建产物及校验文件位于 `dist/`。自定义 SDK 路径、仅构建原生桥接库等选项见 [DESKTOP.md](DESKTOP.md)。Linux ARM64 仅预留构建支持，尚未交付或实测；Linux ARM64 SDK 不能作为 Android SDK 使用。

### macOS

需要 Xcode Command Line Tools 和 macOS SDK 包：

```bash
SDK_PATH="$HOME/Downloads/CrSDK_v2.02.00_20260610a_Mac" bash Scripts/build.sh
```

`SDK_PATH` 支持含 `SimpleCli.zip`，或已解包为 `app/CRSDK` 与 `external/crsdk` 的 SDK 根目录。脚本默认按本机架构编译，应用生成在仓库上一层；可通过 `APP_PATH` 和 `BUILD_DIR` 修改输出位置。应用使用本机 ad-hoc 签名。

## 测试与验证

Windows / Linux 构建脚本自动运行 C++ mock SDK 测试。界面与本地录像的离线测试需在已安装桌面依赖的 Python 环境运行：

```bash
python -m unittest discover -s Sources/Desktop -p 'test_*.py' -v
```

发行程序还支持命令行启动检查，可验证 Qt、SDK 初始化、相机枚举、状态查询和退出；不会连接相机或拍摄。具体命令及显式实机测试工具见 [自动检查说明](DESKTOP.md#自动检查)。

macOS 离线测试：

```bash
SDK_PATH="$HOME/Downloads/CrSDK_v2.02.00_20260610a_Mac" bash Scripts/test-camera-bridge.sh
bash Scripts/test-local-video.sh
```

2026-09-22 的验证结果：

- **Windows / ILX-LR1**：USB 连接、参数读取、实时取景、单张 HEIF、Lo 档 0.5 秒连拍及手动对焦通过；共 3 张 HEIF 完整解码，主图为 9504×6336。
- **Linux / Debian 12**：C++ 编译、DEB 安装、普通用户启动、SDK 初始化及 WSLg X11 / Wayland 检查通过；未进行真实 KDE 会话或 Linux USB 相机测试。
- **Windows / Linux 离线测试**：两平台 C++ mock 测试及各 8 项 Python 界面 / 录像测试通过。
- **macOS / ILX-LR1（v1.2.0）**：USB PC Remote、无存储卡；两轮 Mid 连拍各 3 张，12 个 RAW / HEIF 文件完整回传，6 个 HEIF 完整解码为 9504×6336；连拍后单张拍摄、近远微调和指定焦位回读正常。

完整范围和限制见 [桌面版验证记录](DESKTOP_VALIDATION.md)。

## 代码与文档

- [Sources/Portable/CameraBridge.cpp](Sources/Portable/CameraBridge.cpp)：Windows / Linux C++ 相机控制层。
- [Sources/Desktop/](Sources/Desktop/)：Qt 界面、桥接调用、本地 AVI 录制及 Python 测试。
- [Sources/CameraBridge.mm](Sources/CameraBridge.mm)、[Sources/CameraModel.swift](Sources/CameraModel.swift)：macOS SDK 桥接与应用状态。
- [Sources/LR1ControlApp.swift](Sources/LR1ControlApp.swift)、[Sources/LocalVideoRecorder.swift](Sources/LocalVideoRecorder.swift)：macOS 界面与 MOV 录制。
- [Scripts/](Scripts/)、[Packaging/](Packaging/)：构建脚本、驱动安装、Linux 桌面入口和 USB 权限规则。
- [Tests/](Tests/)：原生离线测试及需显式启用的实机验证工具。

[Windows / Linux 桌面版说明](DESKTOP.md) · [macOS 使用说明](使用说明.md) · [验证记录](DESKTOP_VALIDATION.md) · [更新记录](CHANGELOG.md) · [第三方组件与许可证](THIRD_PARTY_NOTICES.md)
