# LR1 Control

用于 Sony ILX-LR1 的 macOS 原生桌面控制软件，使用 SwiftUI 和 Camera Remote SDK 2.02。支持 USB PC Remote 连接、无卡拍照直传、原生连拍与手动调焦。

## 功能

- 搜索和连接相机，显示实时取景。
- 读取并调整相机当前允许修改的曝光、快门、光圈、ISO、白平衡及照片格式。
- 无存储卡拍摄，照片按相机格式直接保存到 Mac。
- 原生连拍：读取可用档位，支持 0.5–10 秒自动停止及提前停止；每轮独立文件夹，RAW＋JPEG/HEIF 按完整照片计数。
- 手动对焦：近焦/远焦，细、中、粗步进，指定归一化焦位，实际位置回读和停止调焦。
- 运行日志及下载记录。
- 保留实时取景画面的本地 MOV 录制功能；这项功能保存 SDK 取景画面，不是相机机内视频。

## 安装与连接

从本仓库 [Releases](https://github.com/Kiriusss/LR1-Control/releases) 下载 Apple silicon 安装包，解压后打开 `LR1 Control.app`。运行环境为 macOS 13 或更新版本。

相机接独立电源，使用 USB 数据线连接电脑，并选择 **PC Remote**。软件会检查无卡释放快门及仅电脑保存设置。点击“搜索”和“连接相机”即可。

默认照片位置：`~/Pictures/LR1 Captures`。连接超时时，检查“预览”“图像捕捉”及其他相机软件是否占用设备。

完整说明见 [使用说明](使用说明.md)。

## 构建

需要 Xcode Command Line Tools 和已下载的 Camera Remote SDK 2.02 macOS 包。

```sh
SDK_PATH="$HOME/Downloads/CrSDK_v2.02.00_20260610a_Mac" bash Scripts/build.sh
```

`SDK_PATH` 也支持含 `app/CRSDK`、`external/crsdk` 的已解包 SDK 根目录。构建脚本默认按本机架构编译，将应用生成到仓库上一层；可通过 `APP_PATH` 和 `BUILD_DIR` 修改输出位置。应用使用本机 ad-hoc 签名。

SDK 开发包由使用者自行准备；仓库不包含 SDK 开发包、相机照片或本机日志。

## 测试

```sh
SDK_PATH="$HOME/Downloads/CrSDK_v2.02.00_20260610a_Mac" bash Scripts/test-camera-bridge.sh
bash Scripts/test-local-video.sh
```

桥接测试使用 mock SDK 调用，不连接相机。覆盖连拍文件配对、重复回调、定时停止、回传失败、手动对焦参数与取消、超时，以及首次连接失败清理。

2026-09-22 实机验证：USB PC Remote、无存储卡；两轮 Mid 连拍各 3 张，12 个 RAW/HEIF 文件完整传回，6 个 HEIF 均完整解码为 9504×6336。连拍后单张拍摄正常；近远微调和指定焦位均有实际位置回读。

## 代码结构

- `Sources/CameraBridge.mm`：相机 SDK、拍摄状态与文件回传。
- `Sources/CameraModel.swift`：应用状态与后台调用队列。
- `Sources/LR1ControlApp.swift`：SwiftUI 界面。
- `Sources/LocalVideoRecorder.swift`：取景画面本地录制。
- `Scripts/`：构建、图标与测试脚本。
- `Tests/`：离线测试。

第三方组件说明和许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
