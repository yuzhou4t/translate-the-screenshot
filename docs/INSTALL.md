# TTS 安装与首次使用

## 下载

在 [GitHub 最新发布页](https://github.com/yuzhou4t/translate-the-screenshot/releases/latest) 下载 `TTS-版本号-macOS-universal.dmg`，也可选择同版本的 `.zip`。不要把 GitHub 自动生成的 `Source code` 当作安装包。

- 要求 macOS 15 或更新版本。
- 通用包包含 Apple 芯片（arm64）和 Intel（x86_64）程序，无需安装 Swift、Xcode 或自行编译。
- Windows、Linux 和 macOS 14 及更早版本暂不支持。

## 安装和打开

1. 打开 `.dmg`，将 `TTS.app` 拖入 `Applications`；使用 `.zip` 时，解压后把 `TTS.app` 移入“应用程序”。
2. 从“应用程序”打开 TTS。它常驻屏幕右上角菜单栏，没有独立的主窗口。
3. 当前发布包使用 ad hoc 签名，**未使用 Apple Developer ID 签名，也未经过 Apple 公证**。第一次打开可能被 macOS 阻止。确认来源是本仓库后，在“系统设置 → 隐私与安全性”中找到对应提示，选择“仍要打开”，再按系统提示确认。具体步骤见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。
4. 点击菜单栏 TTS 图标，在弹窗中选择“设置”，配置需要的功能。

无需关闭系统的全局安全检查。受单位管理的 Mac 可能不允许打开未公证软件，应遵从设备管理规则。

## 权限

- **屏幕与系统音频录制**：截图、截图 OCR、截图翻译和录屏需要。
- **辅助功能**：划词翻译、全局快捷键和模拟复制需要。
- **麦克风**：仅在主动开启录屏麦克风时需要。
- 图片文件 OCR 不需要屏幕录制权限。

按功能需要在“系统设置 → 隐私与安全性”授权。如果已授权仍有提示，完全退出并重新打开 `/Applications/TTS.app`。更新后如权限失效，可重新授权；不要同时运行多个位置的 TTS。

## 翻译与 AI 功能

安装包包含当前版本的截图、标注、OCR、翻译、录屏、AI 用量查看和 Codex 账号切换界面。第三方账号、订阅、额度和密钥不随软件提供：

- 截图标注、OCR 和录屏在本机完成；录屏保存到“下载”文件夹。
- `Option + W` 使用 Apple 本地坐标翻译，首次使用某个语言组合时可能需要下载系统语言包。
- 普通文字翻译初始使用 MyMemory 公共服务，需要联网并受其额度限制。可在“设置 → 翻译服务”选择自己的服务商和模型。
- API 翻译需要使用者填写自己的 Key、Endpoint 和模型；Key 保存在本机 macOS Keychain 中。
- Codex 订阅翻译需要本机可用的 Codex CLI 或带有 CLI 的桌面客户端，并已通过自己的 ChatGPT 账号登录；可用模型和额度取决于账号及服务端。
- AI 用量查看依赖对应服务的本机客户端登录或自己的监控 Key。未配置的服务不可直接读取用量。
- Codex 账号切换依赖本机已登记的账号；主动切换时会更新本机 Codex 登录并重启 Codex 桌面客户端，请先处理正在运行的任务。
- 火山图片翻译 Beta 需要自己的火山 AccessKey，并在首次使用时同意上传整张截图。

软件不附带开发者的 API Key、登录状态或个人数据。联网翻译会将所选文字发给对应服务；火山整图翻译会上传整张截图。

## 常用入口

- `Ctrl + A`：截图、标注、复制。
- `Option + D`：划词翻译。
- `Option + A`：输入翻译。
- `Option + S`：截图 OCR 后显示文字译文。
- `Option + W`：Apple 本地坐标翻译。
- `Ctrl + Shift + Z`：原生录屏。

快捷键可在设置中修改。更多功能与说明见 [项目首页](https://github.com/yuzhou4t/translate-the-screenshot)。
