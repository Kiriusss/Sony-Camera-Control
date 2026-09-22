# Windows 与 Debian/KDE 桌面版

桌面版采用 PySide6/Qt 6 界面和 C++17 相机控制层，使用本地 Sony Camera Remote SDK 2.02。原有 macOS SwiftUI 应用和构建脚本仍保留。

## 安装

### Windows x64

解压 `SonyCameraControl-1.3.0-windows-x64.zip`，运行文件夹中的 `SonyCameraControl.exe`。保留 `_internal` 及其子目录；发行包已包含 Python、Qt 和相机 SDK，无需另装 Python。

USB 连接需要 Sony SDK 自带的设备驱动。首次使用时，在设备管理器中为处于 PC Remote 模式的相机安装发行包 `drivers/srcameradriver.inf`，或在管理员 PowerShell 中执行：

```powershell
pnputil /add-driver .\drivers\srcameradriver.inf /install
```

安装后设备应显示为 `Sony Remote Control Camera`，类别为 `libusbK Usb Devices`。驱动安装会替换该相机的 MTP 驱动。需恢复普通 MTP 文件传输时，可在设备管理器中重新选择微软 MTP 驱动。SDK 官方要求 Windows 11；Windows 10 未作为本项目验证目标。

### Debian 12/13，KDE，x86_64

在安装包所在目录执行：

```bash
sudo apt install ./sony-camera-control_1.3.0_amd64.deb
```

随后重新插拔相机 USB，在 KDE 应用菜单中打开 **Sony 相机控制**，或运行 `sony-camera-control`。包中包含 Python、Qt、SDK、桌面入口和 USB 权限规则，系统依赖由 apt 安装。应用以普通桌面用户运行。

支持 Qt 的 X11 与 Wayland 平台插件；如特定 KDE/显卡组合在 Wayland 下遇到显示问题，可在已安装 XWayland 的会话中运行 `QT_QPA_PLATFORM=xcb sony-camera-control`。这不是要求把整个桌面改成 X11。

USB 规则只向活动本地会话开放 Sony 静态图像设备，不开放所有 USB 设备。若其他图像导入程序已经占用相机，先退出占用程序，再搜索设备。

`.tar.gz` 是可解压运行的目录包；它不会自动安装系统依赖、桌面入口和 udev 规则，Debian/KDE 优先使用 `.deb`。

## 功能与保存

- 搜索、USB/网络连接、网络认证、实时取景、相机可写参数。
- 单张照片、0.5–10 秒原生连拍、独立连拍文件夹、RAW/JPEG/HEIF 文件配对与下载状态。
- 相机和镜头支持的手动对焦步进、指定位置、实际位置回读及取消。
- 默认保存到用户主目录 `Pictures/Sony Captures`，支持中文保存路径；日志和照片列表可在界面查看。macOS 版继续沿用 `Pictures/LR1 Captures`。
- 本地预览录制为 **MJPEG AVI，5 fps，无音轨**，保留接收到的 JPEG 帧，重复最近帧以保持经过时间。不触发相机机内录像，与 Mac 版本的 H.264 MOV 封装不同。单文件达到 1 GiB 前停止，避免经典 AVI 文件大小溢出。

参数可用性、无卡拍摄和镜头调焦由相机及固件决定。关闭应用会先停止快门和调焦、结束本地录像，再释放 SDK。

## 重新构建

SDK ZIP 放在仓库根目录即可，构建脚本按当前系统和架构选择 `Win64`、`Linux64PC` 或 `Linux64ARMv8`。也可以传入 `--sdk` 指定 ZIP、解包后的 SDK 根目录或 SimpleCli 目录。SDK 与生成的程序不会加入 Git。

Windows 需要 Python 3.12、Visual Studio C++ Build Tools（x64 编译器和 Windows SDK）：

```powershell
powershell -ExecutionPolicy Bypass -File Scripts/build-windows.ps1
```

Debian 12/13 需要以下构建与运行依赖：

```bash
sudo apt install build-essential cmake ninja-build python3-venv libpython3-dev libudev-dev libxml2 libglib2.0-0 \
  libgl1 libegl1 libopengl0 libxcb-cursor0 libxkbcommon-x11-0 libxrender1 libxi6 \
  libxrandr2 libxcursor1 libxcomposite1 libxdamage1 libxtst6 libnss3 libasound2 \
  libdbus-1-3 libfontconfig1 libxcb-shape0 libxcb-icccm4 libxcb-keysyms1 libgtk-3-0 fonts-noto-cjk
bash Scripts/build-linux.sh
```

输出位于 `dist/`，旁边的 `.sha256` 文件用于校验。建议在 Debian 12 构建 x86_64 包，以保持 Debian 12 的最低运行要求；在更新系统构建时，包的 glibc 最低要求跟随构建系统。

本次交付 x86_64，**没有交付或实测 ARM64 安装包**。脚本预留 ARM64 原生构建：PySide6 6.8.3 的 ARM64 wheel 要求 glibc ≥ 2.39，需要 Debian 13 或更新系统；Debian 12 ARM64 仅可使用 `--native-only` 构建相机桥接库。必须使用 Linux64ARMv8 SDK，不能把它当作 Android SDK。

## 自动检查

发行程序支持无需操作屏幕的启动检查：

```text
SonyCameraControl --smoke-test --offscreen --smoke-output smoke.json --screenshot smoke.png
```

此命令检查 Qt 启动、SDK 初始化、相机枚举、状态查询与退出；不会连接或拍摄。它不替代实机功能测试。C++ mock 测试覆盖拍摄/连拍/调焦状态机；Python 测试验证本地录像文件结构。

构建脚本会自动执行 CTest。界面与录像的离线测试为：

```bash
python -m unittest discover -s Sources/Desktop -p 'test_*.py' -v
```

`hardware_validation` 是显式选择的 CMake target，默认不编译、不运行。它需要 `--run-hardware BRIDGE_PATH OUTPUT_JSON PHOTO_DIRECTORY`，会实际拍摄单张及短连拍，并测试手动对焦；仅在相机已准备好时运行。测试程序和桥接库旁必须保留 `CrAdapter`。
