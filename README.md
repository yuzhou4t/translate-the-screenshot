# TTS

TTS 是一个轻量的 macOS 菜单栏翻译与 OCR 工具，专注于这条主链路：

`划词 / 截图 / 图片 OCR -> 文本清理 -> AI 翻译 -> 悬浮结果或图片覆盖预览`

它不是词典型产品，也不做复杂模型路由。当前阶段的重点是：

- 轻量
- 快
- 原生 macOS 体验
- OCR 后处理质量
- 多服务商可切换
- 截图翻译覆盖可用且稳定

## 当前能力

### 核心功能

- `Option + D` 划词翻译
- `Option + A` 输入翻译
- `Option + S` 截图翻译
- `Shift + Option + A` 截图翻译覆盖
- `Shift + Option + S` 截图 OCR
- `Option + C` 静默截图 OCR，并直接复制识别结果
- 菜单栏 `图片文件 OCR...`

### OCR 能力

- 基于 Apple Vision 的本地 OCR
- OCR 规则后处理
  - 去多余空行
  - 修复英文断行
  - 合并短行
  - 修复中英文空格
  - 尽量保留 URL、数字、单位、列表、代码结构
- OCR AI 修复
  - 通过 `TranslationMode.ocrCleanup`
  - 只修复原文，不做翻译
  - 保留代码、专有名词、数字、URL
- 图片文件 OCR 与截图 OCR 共享同一结果面板
- OCR 结果支持
  - 复制文本
  - 查看原始 OCR 文本
  - AI 修复
  - 继续翻译

### 翻译能力

- 普通翻译支持传统翻译服务和 AI 大模型服务
- AI 翻译模式已接入真实 prompt，不再只是 UI 选项
- 当前支持的模式：
  - 快速翻译
  - 准确翻译
  - 自然表达
  - 学术翻译
  - 技术翻译
  - OCR 修复
  - 双语输出
  - 翻译并润色
  - 图片覆盖翻译

### 截图翻译覆盖

截图翻译覆盖已经是完整链路，而不是只做底层实验：

1. 截图
2. OCR 文本块识别
3. 文本块合并
4. `imageOverlay` 批量翻译
5. 覆盖渲染
6. 预览窗口展示

当前支持：

- `solid` 纯色覆盖
- `translucent` 半透明覆盖
- `bubble` 气泡覆盖

预览窗口支持：

- 复制图片
- 保存为 PNG
- 切换覆盖样式
- 重新生成
- 缩放查看

截图覆盖翻译还包含这些优化：

- 批量翻译而不是逐块大量请求
- 按 `id` 返回 JSON，尽量稳定解析
- 同一轮重复文本去重
- 运行期内存缓存
- 场景级 fallback
- 单个 block 失败不拖垮整张图
- fallback 失败时可保留原文继续出图

## 翻译服务与配置

### 已接入服务商

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

### 模型与 API Key

- API Key 保存在 Keychain
- 服务商配置集中在“翻译服务”页
- AI 服务商支持建议模型下拉，同时允许手填自定义模型
- DeepSeek、GLM、Gemini、SiliconFlow、OpenAI 兼容接口都已补充常用模型建议

### fallback

TTS 当前只保留轻量 fallback，不做复杂路由：

- 默认先用当前服务商 / 当前模型
- 失败后最多再试一个备用服务商 / 备用模型
- 不做无限重试
- OCR AI 修复和截图覆盖翻译都支持自己的场景 fallback

## 场景配置

现在可以按场景配置不同的服务商和模型：

- 划词翻译
- 输入翻译
- 截图翻译
- OCR AI 修复
- 截图覆盖翻译

每个场景支持：

- 使用全局默认配置
- 主要服务商
- 主要模型
- 是否启用备用服务
- 备用服务商
- 备用模型

场景配置的目标不是做工程级路由，而是让用户只需要理解一件事：

“这个功能主要用哪个服务，失败时用哪个备用服务。”

## 界面与交互

### 悬浮翻译窗口

- 非抢焦点显示
- 支持钉住
- 支持复制和收藏
- 支持切换 AI 模式后重译
- 支持上一版 / 当前版对比

### 历史记录与收藏

- 翻译结果会写入历史记录
- 可从结果窗口直接收藏
- 历史记录支持搜索、复制、删除、清空
- 收藏夹独立保留
- 清空历史记录前会弹确认
- 删除历史记录不会自动删除收藏

## 权限说明

TTS 需要的权限：

- 辅助功能
  - 用于读取选中文字
- 屏幕录制
  - 用于截图 OCR
  - 用于截图翻译
  - 用于截图翻译覆盖
- 图片文件 OCR
  - 不需要屏幕录制权限

如果系统里已经授权，但应用仍显示未授权，请完全退出后重新打开 `/Applications/TTS.app`。macOS 会按具体 app 路径记录权限。

## 构建与打包

### 本地运行

```sh
swift build
swift run
```

启动后，TTS 会出现在 macOS 右上角菜单栏。

### 打包 macOS App

```sh
scripts/build_app.sh
```

产物位置：

```text
build/Release/TTS.app
```

安装到 `/Applications`：

```sh
rm -rf /Applications/TTS.app
cp -R build/Release/TTS.app /Applications/
open /Applications/TTS.app
```

### Xcode 构建

```sh
xcodebuild -project tts.xcodeproj -scheme tts -configuration Release build
```

## 文档入口

建议先看这些文档：

- [README.md](README.md)
- [docs/PRODUCT_ROADMAP.md](docs/PRODUCT_ROADMAP.md)
- [docs/DIFFERENTIATION.md](docs/DIFFERENTIATION.md)
- [docs/CHANGELOG.md](docs/CHANGELOG.md)

如果要理解实现层，优先看：

- [TranslationModels.swift](Sources/TTS/Models/TranslationModels.swift)
- [PromptBuilder.swift](Sources/TTS/App/PromptBuilder.swift)
- [TranslationService.swift](Sources/TTS/App/TranslationService.swift)
- [ScenarioTranslationResolver.swift](Sources/TTS/App/ScenarioTranslationResolver.swift)
- [OCRService.swift](Sources/TTS/OCR/OCRService.swift)
- [OCRTextBlockGrouper.swift](Sources/TTS/OCR/OCRTextBlockGrouper.swift)
- [ImageOverlayBatchTranslator.swift](Sources/TTS/Screenshot/ImageOverlayBatchTranslator.swift)
- [ScreenshotTranslationOverlayRenderer.swift](Sources/TTS/Screenshot/ScreenshotTranslationOverlayRenderer.swift)
- [TranslatedImagePreviewWindow.swift](Sources/TTS/Screenshot/TranslatedImagePreviewWindow.swift)
- [SettingsView.swift](Sources/TTS/UI/Settings/SettingsView.swift)

## 说明

- 仓库不提交 `.app` 构建产物、本地缓存或任何密钥
- API Key 应保存在 Keychain
- 当前路线保持轻量化，不重新引入模型评分、翻译偏好或复杂模型路由
