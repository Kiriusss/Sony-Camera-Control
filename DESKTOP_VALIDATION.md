# Sony Camera Control 1.3.0 构建验证

日期：2026-09-22。使用用户提供的 Sony Camera Remote SDK 2.02。全程通过命令行、SDK、自动测试和 Qt 自身抓图验证，未使用 computer use。

## 交付

- `SonyCameraControl-1.3.0-windows-x64.zip`：Windows 11 x64 目录包，解压后运行 `SonyCameraControl.exe`。
- `sony-camera-control_1.3.0_amd64.deb`：在 Debian 12 构建的 x86_64 安装包，含桌面入口、图标、SDK 和 udev 规则。
- `SonyCameraControl-1.3.0-linux-x64.tar.gz`：Linux 目录包，需要自行准备系统依赖。
- 三个包的 SHA-256 均已与各自 `.sha256` 文件核对一致；Windows ZIP 完整性校验通过，未混入实机测试程序。

安装与重新构建步骤见仓库 `DESKTOP.md`。本轮没有交付 ARM64、Android 或鸿蒙应用。

## Windows 实机

已按用户授权安装 SDK 内签名有效的 Sony USB 驱动，设备由 MTP 切换为 Sony Remote Control Camera / libusbK。测试机型为 ILX-LR1。

- SDK 初始化、枚举、连接、拍摄参数读取、实时取景 JPEG、断开及释放通过。
- 单张 HEIF 回传 1 张；Lo 档 0.5 秒连拍回传 2 张，文件分组与回传结束状态正常。
- 3 张 HEIF 的全部图像流经 FFmpeg 完整解码通过；主图分块拼接为 9504×6336 后解码通过。
- 保存目录为 `build/hardware-captures/实机验证`，验证了中文路径。
- MF 近远最小步进有实际位置回读；指定焦位后经稳定等待确认恢复原位置 65535，原 AF-C 模式也已恢复。相机已断开，SDK 已释放。
- 最终发行包再次完成初始化、搜索到 1 台 LR1、状态查询及正常退出。包内桥接 DLL 与最新安装阶段 DLL 的 SHA-256 一致。

详细记录：`build/hardware-validation.json`、`build/focus-restoration.json`、`build/hif-validation.json`、`build/final-windows-smoke.json`。

## Linux

使用独立 WSL2 Debian 12 环境 `SonyCameraBuild`，未改动用户原有 Debian 发行版。

- C++ 原生编译与 CTest 通过。
- `.deb` 已实际安装，普通用户的 Qt 离屏启动、SDK 初始化、无相机枚举、状态查询、退出通过。
- 安装后的程序在 WSLg X11 和 Wayland 后端启动检查均通过，平台插件依赖无缺失。
- 已确认安装后的 udev 文件包含 Sony USB 接口识别与活动本地会话授权规则。
- **未在真实 KDE 会话验证；未将相机透传给 Linux，因此 Linux USB 拍摄、KDE 设备占用与实际权限仍需目标机器实测。Debian 13 和 ARM64 未实测。**

详细记录：`build/installed-linux-smoke.json`、`build/installed-linux-x11-smoke.json`、`build/installed-linux-wayland-smoke.json`。

## 离线测试

Windows 与 Linux 的 C++ SDK mock 状态机测试均通过；两平台各 8 项 Python 界面/录像测试通过。测试涵盖串行 SDK 工作线程、拍摄/调焦界面状态、安全关闭、连拍配对及定时停止、参数边界、Unicode 路径、AVI 帧索引与时间处理等。

本地预览 AVI 另经 ffprobe 验证为 MJPEG、640×480、5 fps、10 帧、2 秒。此功能为电脑收到的实时取景录制，不是相机机内视频；与 Mac 版 H.264 MOV 格式不同。
