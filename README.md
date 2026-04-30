# TTS

#### 一个轻量、快速、好用的 macOS 截图翻译与 OCR 工具

![platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![language](https://img.shields.io/badge/language-Swift-orange)
![status](https://img.shields.io/badge/status-active-brightgreen)

TTS 是一个常驻菜单栏的 macOS 翻译工具，支持划词翻译、输入翻译、截图翻译、截图 OCR、图片 OCR 和截图译文覆盖。

主链路是：

```text
划词 / 输入 / 截图 / 图片 OCR -> 文本清理 -> AI 翻译 -> 悬浮结果或图片原位覆盖
```

它适合这些场景：

- 看英文网页、论文、文档时，快速划词翻译。
- 遇到无法复制的图片、截图、软件界面时，直接截图识别并翻译。
- 想把图片里的文字翻译后覆盖回原图，获得更直观的阅读体验。
- 需要在不同翻译服务和 AI 模型之间自由切换。
- 想要一个轻量、不打扰、贴近 macOS 原生体验的菜单栏工具。

TTS 不是复杂的词典软件，也不是大而全的翻译平台。它更专注于一个核心目标：

> 让 macOS 上的划词、截图、OCR 和 AI 翻译变得更快、更自然、更顺手。

## 功能特性

### 多种翻译方式

| 功能 | 默认快捷键 | 说明 |
| --- | --- | --- |
| 划词翻译 | `Option + D` | 选中文本后快速翻译 |
| 输入翻译 | `Option + A` | 打开输入窗口，手动输入文本翻译 |
| 截图翻译 | `Option + S` | 截取屏幕区域，识别文字并翻译 |
| 截图翻译覆盖 | `Shift + Option + A` | 截图后将译文覆盖回原图 |
| 截图 OCR | `Shift + Option + S` | 截图后只识别文字，不自动翻译 |
| 静默截图 OCR | `Option + C` | 截图识别后直接复制文字到剪贴板 |
| 图片文件 OCR | 菜单栏入口 | 选择本地图片并识别文字 |

### OCR 与文本处理

TTS 的 OCR 主路径基于 Apple Vision 本地识别，不需要远端视觉模型。OCR 结果会先经过本地规则后处理：

- 清理多余空行。
- 修复英文断词和断行。
- 合并同一段落中的短行。
- 修复中英文之间不自然的空格。
- 尽量保留 URL、数字、单位、列表、Markdown 和代码结构。

OCR 面板支持复制文本、查看原始 OCR、AI 修复和继续翻译。AI 修复使用 `TranslationMode.ocrCleanup`，只修复原文，不做翻译。

### 截图翻译覆盖

截图翻译覆盖是 TTS 的核心特色功能。你可以截取英文界面、网页、海报、软件窗口或图片，TTS 会识别其中的文字，并把翻译结果覆盖显示在原图上。

当前链路：

1. 用户截图。
2. Apple Vision accurate OCR 识别文字与位置。
3. Swift 版 `AppleOCRLayoutEngine` 按 band、列、section 合并自然翻译区域。
4. 打开覆盖翻译窗口并显示 OCR 框。
5. 用户点击翻译后按 `OverlaySegment` 分批请求模型。
6. 每批译文返回后立即在原图位置回填。
7. 用户可复制图片、保存 PNG 或查看 debug 输出。

覆盖翻译窗口支持：

- `nativeReplace` 自然替换样式。
- 显示或隐藏 OCR 框。
- 选中区域查看原文、译文和状态。
- 排除或重试单个区域。
- 复制 OCR 文本。
- 复制图片或保存 PNG。
- 缩放查看结果。
- 打开 debug 输出目录。

实现上，截图覆盖翻译不依赖 Gemini / OpenAI Vision 分块。它先把 Vision observation 组织成 `OCRLayoutBand` / `OCRLayoutSection`，再生成 `OverlaySegment`。翻译 prompt 会携带 OCR 行骨架，模型可返回 `lineTranslations`，渲染时优先用 `eraseBoxes` 擦除原文，再按 `lineBoxes` 回填译文。

### AI 翻译模式

TTS 内置多种翻译模式，适合不同内容：

- 快速翻译
- 准确翻译
- 自然表达
- 学术翻译
- 技术翻译
- 双语输出
- 翻译并润色
- OCR 修复
- 图片覆盖翻译

### 多服务商支持

TTS 支持多种翻译服务和 AI 服务商：

- OpenAI 兼容接口
- 智谱 GLM
- 硅基流动
- DeepSeek
- Gemini
- DeepL
- Google Cloud Translation
- Microsoft Translator / Bing
- 百度翻译
- 腾讯云机器翻译 TMT
- 火山翻译
- MyMemory

API Key 保存到 macOS Keychain 中，不会明文写入项目文件。你可以在设置页中管理不同服务商的 API Key、Endpoint 和模型名称。

### 场景化配置

TTS 支持按使用场景配置服务商和模型：

- 划词翻译
- 输入翻译
- 截图翻译
- OCR AI 修复
- 截图覆盖翻译

每个场景都可以设置主服务商和备用服务商。主服务不可用时，最多再尝试一个备用服务，不做无限重试或复杂评分路由。

### 悬浮翻译窗口

翻译结果会显示在轻量的悬浮窗口中。

悬浮窗口支持：

- 不抢焦点显示
- 复制译文
- 收藏结果
- 钉住窗口
- 切换翻译模式后重新翻译
- 查看上一版和当前版结果

### 历史记录与收藏

TTS 会保存翻译历史，方便回看之前翻译过的内容。

支持：

- 搜索历史记录
- 复制历史内容
- 删除单条记录
- 清空历史记录
- 收藏重要翻译
- 单独查看收藏夹

删除历史记录不会自动删除收藏内容。

## 安装与运行

环境要求：

- macOS 13 或更新版本
- Swift 6 工具链
- Xcode Command Line Tools

从源码运行：

```sh
swift build
swift run
```

启动后，TTS 会出现在 macOS 右上角菜单栏。

运行测试：

```sh
swift test
```

打包为 macOS App：

```sh
scripts/build_app.sh
```

构建完成后，产物位于：

```text
build/Release/TTS.app
```

安装到 `/Applications`：

```sh
rm -rf /Applications/TTS.app
cp -R build/Release/TTS.app /Applications/
open /Applications/TTS.app
```

如果希望权限在本地开发构建之间更稳定，可以先创建本地代码签名身份：

```sh
scripts/create_local_codesign_identity.sh
```

也可以使用 Xcode 构建：

```sh
xcodebuild -project tts.xcodeproj -scheme tts -configuration Release build
```

## 权限说明

TTS 需要以下 macOS 权限：

| 权限 | 用途 |
| --- | --- |
| 辅助功能 | 用于读取当前选中的文字 |
| 屏幕录制 | 用于截图 OCR、截图翻译和截图翻译覆盖 |
| 文件访问 | 用于选择本地图片并进行 OCR |

图片文件 OCR 不需要屏幕录制权限。

如果已经授权但应用仍提示未授权，请完全退出 TTS，然后重新打开 `/Applications/TTS.app`。macOS 会按具体 App 路径记录权限，移动 App 后可能需要重新授权。

## 项目结构

```text
Sources/TTS/App/          应用服务、快捷键、prompt、翻译流程
Sources/TTS/Models/       翻译模式、服务商配置和场景配置
Sources/TTS/OCR/          Apple Vision OCR、文本后处理和 layout engine
Sources/TTS/Providers/    各翻译服务商实现
Sources/TTS/Screenshot/   截图、覆盖翻译会话、分批翻译和渲染
Sources/TTS/UI/           设置、悬浮窗、历史、收藏、OCR 面板
Tests/TTSTests/           Swift Package 测试
docs/                     产品路线、差异化、变更记录和截图翻译说明
scripts/                  打包与本地签名脚本
```

## 项目状态

TTS 目前处于持续开发阶段，核心功能已经可用，包括：

- 菜单栏常驻
- 划词翻译
- 输入翻译
- 截图翻译
- 截图 OCR
- 图片 OCR
- 截图翻译覆盖
- 多服务商配置
- 场景化模型配置
- 历史记录
- 收藏夹
- App 打包运行

后续会继续优化截图覆盖翻译效果、OCR 识别后的文本排版、服务商稳定性、UI 细节、App 图标与发布流程。

## 文档

- [产品路线图](docs/PRODUCT_ROADMAP.md)
- [差异化说明](docs/DIFFERENTIATION.md)
- [更新记录](docs/CHANGELOG.md)
- [截图翻译实现说明](docs/SCREENSHOT_TRANSLATION.md)

如果要理解实现层，优先看：

- [TranslationModels.swift](Sources/TTS/Models/TranslationModels.swift)
- [PromptBuilder.swift](Sources/TTS/App/PromptBuilder.swift)
- [TranslationService.swift](Sources/TTS/App/TranslationService.swift)
- [ScenarioTranslationResolver.swift](Sources/TTS/App/ScenarioTranslationResolver.swift)
- [OCRService.swift](Sources/TTS/OCR/OCRService.swift)
- [AppleOCRLayoutEngine.swift](Sources/TTS/OCR/AppleOCRLayoutEngine.swift)
- [TextAtom.swift](Sources/TTS/Screenshot/TextAtom.swift)
- [ImageOverlaySession.swift](Sources/TTS/Screenshot/ImageOverlaySession.swift)
- [ImageOverlayTranslationWindow.swift](Sources/TTS/Screenshot/ImageOverlayTranslationWindow.swift)
- [ImageOverlayBatchTranslator.swift](Sources/TTS/Screenshot/ImageOverlayBatchTranslator.swift)
- [ScreenshotTranslationOverlayRenderer.swift](Sources/TTS/Screenshot/ScreenshotTranslationOverlayRenderer.swift)
- [OverlayPipelineDebugWriter.swift](Sources/TTS/Screenshot/OverlayPipelineDebugWriter.swift)
- [SettingsView.swift](Sources/TTS/UI/Settings/SettingsView.swift)

## 贡献

欢迎提交 issue 或 PR。

如果是新的翻译服务商、截图覆盖能力、OCR 优化或 UI 改进，建议先开 issue 说明想法，方便保持项目方向一致。

## 声明

TTS 是一个开源 macOS 翻译与 OCR 工具，主要用于学习、研究和个人效率场景。

请不要将 API Key、访问令牌或其他敏感信息提交到仓库中。使用第三方翻译服务时，请遵守对应服务商的使用条款。
