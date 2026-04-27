# Translate the Screenshot

## 中文

Translate the Screenshot 是一个轻量的 macOS 菜单栏翻译与 OCR 工具，灵感来自Bob和easydict。使用 Swift、SwiftUI、AppKit、Apple Vision 和 Keychain 构建。应用打包为 `TTS.app`，启动后常驻菜单栏，不默认显示主窗口。

TTS 专注于轻量化 AI 截图翻译，而不是传统词典式翻译。

### 主要功能

- `Option + D` 划词翻译
- `Option + A` 输入翻译
- `Option + S` 截图翻译
- `Shift + Option + S` 截图 OCR
- `Option + C` 静默截图 OCR，并直接复制识别文本
- 图片文件 OCR（从菜单栏选择本地图片）
- 不抢焦点的悬浮翻译窗口
- 历史记录和收藏夹
- 多翻译服务商配置和 fallback
- API Key 使用 Keychain 保存
- Accessibility 和 Screen Recording 权限引导
- 基于 Apple Vision 的本地 OCR
- 可生成标准 macOS `.app`，并包含自定义应用图标和菜单栏图标

### 已接入翻译服务

- OpenAI-compatible API
- 智谱 GLM
- 硅基流动 SiliconFlow
- DeepSeek
- Gemini
- DeepL
- Google Cloud Translation
- Microsoft Translator / Bing
- 百度翻译
- 腾讯云机器翻译 TMT
- 火山翻译
- MyMemory 免费测试服务

### 开发构建

```sh
swift build
swift run
```

启动后，TTS 会出现在 macOS 右上角菜单栏。

### 生成 macOS App

```sh
scripts/build_app.sh
```

生成的应用位于：

```text
build/Release/TTS.app
```

安装到应用程序：

```sh
rm -rf /Applications/TTS.app
cp -R build/Release/TTS.app /Applications/
open /Applications/TTS.app
```

### Xcode 构建

如果安装了完整 Xcode，也可以使用：

```sh
xcodebuild -project tts.xcodeproj -scheme tts -configuration Release build
```

### 权限说明

TTS 需要以下 macOS 权限：

- 辅助功能：读取选中文字，并在必要时使用受保护的剪贴板兜底
- 屏幕录制：用于截图 OCR 和截图翻译，不会录音

如果系统设置里已经授权，但 TTS 仍显示未授权，请完全退出 TTS，并重新打开 `/Applications/TTS.app`。macOS 会按具体 app bundle 和路径记录权限。

### 说明

仓库不会提交构建产物、`.app` 包、本地缓存或任何密钥。API Key 应保存在 Keychain 中。

## English

Translate the Screenshot is a lightweight macOS menu bar translation and OCR tool built with Swift, SwiftUI, AppKit, Apple Vision, and Keychain. The app is packaged as `TTS.app` and runs as a menu bar utility without showing a main window by default.

TTS focuses on lightweight AI-first screenshot translation rather than dictionary-style translation.

### Features

- Selection translation with `Option + D`
- Input translation with `Option + A`
- Screenshot translation with `Option + S`
- Screenshot OCR with `Shift + Option + S`
- Silent screenshot OCR with `Option + C`, copying recognized text directly
- Non-activating floating translation panel
- History and favorites
- Configurable translation providers with fallback
- API keys stored in Keychain
- Accessibility and Screen Recording permission guidance
- Local OCR powered by Apple Vision
- Standard macOS `.app` packaging with custom app and menu bar icons

### Translation Providers

- OpenAI-compatible API
- Zhipu GLM
- SiliconFlow
- DeepSeek
- Gemini
- DeepL
- Google Cloud Translation
- Microsoft Translator / Bing
- Baidu Translate
- Tencent Cloud TMT
- Volcengine Translate
- MyMemory free test provider

### Development Build

```sh
swift build
swift run
```

After launch, TTS appears in the macOS menu bar.

### Build The macOS App

```sh
scripts/build_app.sh
```

The generated app is:

```text
build/Release/TTS.app
```

Install it into Applications:

```sh
rm -rf /Applications/TTS.app
cp -R build/Release/TTS.app /Applications/
open /Applications/TTS.app
```

### Xcode Build

If full Xcode is installed:

```sh
xcodebuild -project tts.xcodeproj -scheme tts -configuration Release build
```

### Permissions

TTS needs the following macOS permissions:

- Accessibility: read selected text and use the protected clipboard fallback when needed
- Screen Recording: perform screenshot OCR and screenshot translation; TTS does not record audio
- Image file OCR does not require Screen Recording permission

If permissions look enabled but TTS still reports missing permission, fully quit TTS and reopen `/Applications/TTS.app`. macOS tracks permissions by the concrete app bundle identity and path.

### Notes

This repository intentionally does not commit build output, `.app` bundles, local caches, or secrets. API keys should be stored in Keychain.
