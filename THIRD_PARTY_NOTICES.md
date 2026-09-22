# 第三方组件

本应用通过 Sony Camera Remote SDK 2.02 控制 SDK 支持的 Sony 相机。SDK 库是 Sony 提供的独立组件，其授权见 [Sony Camera Remote SDK License Agreement](https://support.d-imaging.sony.co.jp/app/sdk/licenseagreement/en.html)。源码仓库不包含 SDK 开发包。

Windows/Linux 桌面版另使用以下组件，发行包 `licenses/` 保存许可证：

- PySide6-Essentials / Shiboken 6.8.3 与 Qt 6.8.3，动态链接，按 LGPLv3/GPLv3 或相应组件的许可使用。LGPL 与 GPL 完整文本位于 `ThirdPartyLicenses/Desktop/`；用户可替换发行目录中的对应动态库，不限制为调试此类修改进行逆向工程的权利。对应源码：[Qt for Python 6.8.3](https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-6.8.3-src/)、[Qt 6.8.3](https://download.qt.io/archive/qt/6.8/6.8.3/single/)。
- Python，PSF 许可证；Windows 构建使用 3.12，Debian 构建使用系统 Python 3.11 或更新版本，发行包携带构建时对应运行库。
- PyInstaller 6.16.0，GPL 与 bootloader 分发例外，文本位于 `ThirdPartyLicenses/Desktop/PyInstaller-COPYING.txt`。
- nlohmann/json 3.11.3，MIT；源码头文件及许可证位于 `ThirdParty/nlohmann/`。
- Windows 发行包随附构建工具提供的 Microsoft Visual C++ Runtime，其分发与使用适用 Microsoft Visual Studio 运行库条款。

桌面包保留 Sony SDK 的 `CrAdapter` 目录，部分动态库因此在启动器旁和 `_internal/native/` 各保留一份。它们均来自本地对应平台 SDK，许可证不因打包方式变化而改变。

应用包中保留 SDK 动态库及其目录关系；macOS 构建时对库进行本机 ad-hoc 签名。Windows/Linux 构建不添加应用代码签名。第三方组件许可分别适用，不因存入本仓库而改变。

`ThirdPartyLicenses/` 保存供应商 SDK 中的原始声明：

- `Sony-SDK-OSS-NOTICES.md`：SimpleCli 包随附 README，含供应商完整开源组件声明。
- `libusb-LGPL-2.1.txt`：libusb 的 LGPL 2.1 文本。
- `libssh2-COPYING.txt`：libssh2 原始版权和许可。
- `OpenSSL-APACHE-2.0.txt`：OpenSSL 原始许可。
- `OpenCV-APACHE-2.0.txt`：OpenCV 原始许可。

供应商随本版本 SDK 提供的 libusb 对应源代码原包，以 `libusb-source-sdk-2.02.zip` 附在本仓库同一版本 Release 中。libusb 为动态链接库：macOS 位置为 `Contents/Frameworks/CrAdapter/libusb-1.0.0.dylib`；Windows/Linux 包分别在 `CrAdapter/` 和 `_internal/native/CrAdapter/` 保留 `libusb-1.0.dll` 或 `libusb-1.0.so`。
