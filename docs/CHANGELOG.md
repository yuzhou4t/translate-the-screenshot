# TTS 修改记录

本文件用于记录 TTS 的产品、UI、配置和核心能力变更，方便后续回看设计取舍与开发进度。

## 2026-04-26

### 产品定位与文档

- 新增 `docs/PRODUCT_ROADMAP.md`，明确 TTS 的产品定位、不做什么、阶段路线、近期优先级和 MVP 标准。
- 新增 `docs/DIFFERENTIATION.md`，说明 TTS 与 Bob / Easydict 的差异，以及轻量、AI-first、OCR 后处理、模型路由和 fallback 的核心方向。
- 更新 `README.md` 顶部简介，强调 TTS 专注轻量化 AI 截图翻译，而不是传统词典式翻译。

### macOS 外观适配

- 移除强制浅色模式逻辑，让应用跟随 macOS 系统深色/浅色外观。
- 调整主要 UI 使用系统颜色，提升深色模式和浅色模式下的可读性。

### 悬浮翻译窗口

- 修复截图翻译加载期间移动窗口后，结果出现时窗口回到初始位置的问题。
- 修复加载期间关闭悬浮窗口后，翻译完成仍重新弹出窗口的问题。
- 将悬浮翻译窗口改为更现代的 macOS 卡片式 UI，包含原文、译文、状态提示和底部操作区。
- 保持悬浮窗口不抢焦点，并继续显示在鼠标附近。
- 修复原文/译文字号不一致、原文无法滚动、底部复制和收藏按钮不可见的问题。
- 新增 AI 模式重译入口，支持在悬浮窗口中切换翻译风格后重新翻译。
- 将上一版和当前版对比从独立弹窗改为悬浮窗口内联展开，切换风格后用动画展开为左右对比布局。
- 新增钉住按钮，钉住后点击空白处不会关闭悬浮窗口。
- 增大悬浮窗口和对比模式尺寸，提高原文、译文和错误信息字号，减少窗口空洞感并提升阅读性。
- 统一悬浮窗口正文阅读字号，原文、译文、对比内容和错误信息都使用接近译文的字号，并压缩状态区留白，让布局更紧凑。
- 调整悬浮窗口内容区高度和 footer 布局优先级，确保复制、收藏和关闭按钮始终可见；同时增强对比模式中上一版和当前版的视觉区分。

### 设置页信息架构

- 将设置页重构为分区结构：通用、快捷键、翻译服务、AI 模式、模型配置、权限与隐私。
- 保留 Provider、Endpoint、Model、Target Language、API Key、快捷键和权限状态等原有设置能力。
- 统一快捷键设置页与其他设置分区的 UI 表现。
- 移除权限与隐私页中多余的“检查权限”按钮。
- API Key 继续使用 Keychain 保存，不改变原有存储方式。

### 翻译方向与服务商分组

- 将目标语言输入改为翻译方向选择，支持自动检测到中文、自动检测到英文、英文到中文、中文到英文、日文到中文、韩文到中文和自定义。
- 设置页和输入翻译窗口都使用翻译方向选择器。
- 翻译方向选择器使用系统 bordered 按钮样式，让选中项常态显示灰色按钮背景。
- 在翻译服务设置中区分 AI 大模型服务商和传统翻译服务商。

### AI 翻译模式

- 新增 `TranslationMode` 数据结构，包含快速翻译、准确翻译、自然表达、学术翻译、技术翻译、OCR 修复翻译、双语输出、翻译并润色。
- 每个 AI 翻译模式提供显示名、说明、系统 prompt 和用户 prompt 模板。
- 在配置中保存默认 AI 翻译模式，旧配置缺失时默认使用准确翻译。
- 设置页 AI 模式分区支持选择默认 AI 翻译模式。
- 将 AI 翻译模式接入大模型类 Provider 请求构造，包括 OpenAI-compatible、GLM 和 SiliconFlow。
- 传统翻译服务商保持原有行为，不强行使用 prompt。
- 翻译历史记录本次使用的 AI 翻译模式，旧历史记录兼容默认准确翻译。
- 优化学术翻译 prompt，使其更偏论文/报告风格，强调术语一致、逻辑清晰、客观语气和不添加原文外信息。

### 精细化模型配置

- 新增 `ModelPurpose`，包含快速、高质量、学术、技术、OCR 修复和备用用途。
- 新增 `ModelCapabilityScore`，记录速度、质量、学术、技术、OCR 修复、格式遵循和成本效率评分。
- 新增 `ModelProfile`，保存模型名称、Provider、实际 model name、用途、优先级、启用状态和能力评分。
- `AppConfigurationStore` 开始保存 `modelProfiles`，旧配置缺失时自动补齐默认 profiles。
- 默认提供 Fast Model、Quality Model、Academic Model、Technical Model、OCR Cleanup Model 和 Fallback Model。
- 设置页“模型配置”分区改为 profile 列表和详情编辑，允许修改名称、Provider、Model Name、用途、优先级和启用状态。
- 当前模型 Profile 仅用于配置准备，暂不接入真实翻译路由和 fallback 逻辑。
- 新增 `TranslationScenario` 和 `TranslationRouter`，可根据场景、模型 Profile 和可选 AI 翻译模式推荐最合适的模型 Profile。
- `TranslationRouter` 支持 selection、input、screenshot、ocrCleanup、technical、academic 场景，按用途优先级、启用状态、priority 和能力评分排序，暂不发起网络请求。
- 新增 `TranslationRouterRuleChecks.runBasicRoutingChecks()` 简单校验函数，覆盖 fast 选择、academic fallback、disabled 跳过和 priority 排序。

### 工作流约定

- 后续开发默认直接在 `main` 上修改。
- 每次修改后继续运行 `swift build`，并检查 `git diff` 与 `git status`。
- 重要产品、UI、配置和行为变更继续追加记录到本文档。
