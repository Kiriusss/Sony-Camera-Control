# 第三方组件

本应用通过 Sony Camera Remote SDK 2.02 控制 SDK 支持的 Sony 相机。SDK 库是 Sony 提供的独立组件，其授权见 [Sony Camera Remote SDK License Agreement](https://support.d-imaging.sony.co.jp/app/sdk/licenseagreement/en.html)。源码仓库不包含 SDK 开发包。

应用包中保留 SDK 动态库及其目录关系；构建时对库进行本机签名。第三方组件许可分别适用，不因存入本仓库而改变。

`ThirdPartyLicenses/` 保存供应商 SDK 中的原始声明：

- `Sony-SDK-OSS-NOTICES.md`：SimpleCli 包随附 README，含供应商完整开源组件声明。
- `libusb-LGPL-2.1.txt`：libusb 的 LGPL 2.1 文本。
- `libssh2-COPYING.txt`：libssh2 原始版权和许可。
- `OpenSSL-APACHE-2.0.txt`：OpenSSL 原始许可。
- `OpenCV-APACHE-2.0.txt`：OpenCV 原始许可。

供应商随本版本 SDK 提供的 libusb 对应源代码原包，以 `libusb-source-sdk-2.02.zip` 附在本仓库同一版本 Release 中。libusb 为动态链接库，应用包内位置为 `Contents/Frameworks/CrAdapter/libusb-1.0.0.dylib`。
