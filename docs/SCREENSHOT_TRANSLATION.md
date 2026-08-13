# 截图翻译实现说明

本文档用于理解 TTS 的截图到剪贴板、截图翻译、截图 OCR 和图片翻译。它按当前代码状态书写，优先解释各条链路的数据与隐私边界。

## 先看什么

如果只想理解产品和当前能力，先看：

- [README.md](../README.md)：项目入口、快捷键、能力范围和构建方式。
- [CHANGELOG.md](CHANGELOG.md)：最近为什么这样改，特别是截图覆盖翻译从 OCR block 到本地语义分块、行骨架翻译和 `nativeReplace` 的演进。
- [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md)：产品边界，尤其是“轻量、快速、原生 macOS、不做复杂视觉模型路由”。
- [DIFFERENTIATION.md](DIFFERENTIATION.md)：TTS 和 Bob / Easydict 的差异，帮助判断截图翻译相关功能是否符合项目方向。

如果要理解截图覆盖翻译实现，建议按这个顺序读代码：

1. `Sources/TTS/Screenshot/ScreenshotCaptureController.swift`
2. `Sources/TTS/Screenshot/ScreenshotOverlayWindow.swift`
3. `Sources/TTS/Screenshot/ScreenshotAnnotation.swift`
4. `Sources/TTS/OCR/OCRService.swift`
5. `Sources/TTS/OCR/AppleOCRLayoutEngine.swift`
6. `Sources/TTS/Screenshot/TextAtom.swift`
7. `Sources/TTS/Screenshot/ImageOverlaySession.swift`
8. `Sources/TTS/Screenshot/ImageOverlayTranslationWindow.swift`
9. `Sources/TTS/Screenshot/ImageOverlayBatchTranslator.swift`
10. `Sources/TTS/App/PromptBuilder.swift`
11. `Sources/TTS/Screenshot/ScreenshotTranslationOverlayRenderer.swift`
12. `Sources/TTS/Screenshot/OverlayPipelineDebugWriter.swift`

## 六条截图相关链路

### 截图到剪贴板

默认快捷键是 `Ctrl + A`。快捷键触发后会先在内存中冻结每块显示器的当前画面，用户再在静态画面上拖动框选；框选期间会显示实时尺寸。进入轻量标注界面后默认使用移动工具：拖动选区内部可整体换位置，拖动四边或四角可重新调整尺寸，方向键可按 1 pt 微调、`Shift + 方向键` 可按 10 pt 微调；macOS 已开启“三指拖移”时会按普通拖拽事件工作。切换到矩形、箭头或马赛克工具后，原地长按约 0.32 秒也可临时移动选区。标注工具栏优先位于选区下方，空间不足时才回退到选区内或上方。

数据流：

```text
ScreenshotCaptureController 预抓取各显示器画面
-> ScreenshotOverlayWindow 在冻结画面上框选区域
-> 从对应显示器快照裁切选区
-> ScreenshotAnnotationWindow / ScreenshotAnnotationRenderer
-> NSPasteboard
```

这条链路不创建截图文件，不运行 OCR 或翻译，也不发起网络请求。取消时不会改动剪贴板；复制成功后只把最终图片写入系统剪贴板。

### 截图文字翻译（辅助入口）

截图文字翻译的目标是得到一段可读译文，不需要图片覆盖。默认使用 `Option + S`，OCR 和翻译完成后在文字悬浮窗中显示结果。

数据流：

```text
ScreenshotCaptureController
-> OCRService.recognizeText
-> OCRTextPostProcessor
-> TranslationService.translate
-> FloatingTranslatePanel
```

重点看：

- `OCRService.recognizeText(from:mode:)`
- `OCRTextPostProcessor`
- `TranslationService.translate(...)`
- `FloatingTranslatePanel`

### 截图 OCR / 静默 OCR

截图 OCR 只做识别和文本展示；静默 OCR 会直接复制文本。

数据流：

```text
ScreenshotCaptureController
-> OCRService.recognizeText
-> OCRTextPostProcessor
-> OCRResultPanel 或剪贴板
```

重点看：

- `OCRResultPanel`
- `OCRTextPostProcessor`
- `TranslationMode.ocrCleanup`，它只做 OCR 修复，不做翻译。

### API 高质量坐标翻译

可在快捷键设置中录制独立快捷键。主路径在本机完成 Apple Vision OCR、版式分析和坐标生成，只把 OCR 分段文字和必要的段落结构信息交给全局默认翻译服务，并将返回译文按原坐标回填。默认翻译服务失败时，失败段最多尝试一次全局备用服务。

数据流：

```text
ScreenshotCaptureController
-> OCRService.recognizeOverlaySnapshot(.accurate)
-> AppleOCRLayoutEngine
-> TranslationService.translateImageOverlaySegmentsIncrementally
-> OverlayCanvasView 实时绘制
-> ScreenshotTranslationOverlayRenderer 导出图片
```

截图像素与坐标不会发送给默认文字翻译 API。结果窗口中的“API 高质量重译”按钮会复用相同配置重新翻译全部可翻译分段；失败时保留已有可用结果或原文。

### 火山图片翻译 Beta

火山图片翻译是单独链路，可从菜单或已配置的独立快捷键启动。它直接调用火山 `TranslateImage` 整图翻译接口，不先运行本地 OCR。

数据流：

```text
ScreenshotCaptureController
-> ImageOverlayTranslationWindowController 立即显示冻结截图
-> VolcengineImagePayloadEncoder 本地校验和压缩
-> VolcengineImageTranslationPolicyStore 预占本月次数
-> VolcengineTranslateProvider.translateImage
-> 同一窗口显示火山返回的整图
```

主路径规则：

- 第一次使用会询问是否允许上传完整截图；同意记录可在设置中撤销。
- 提交前查询火山账号本自然月图片用量，并与本机保守计数取较大值；第 100 次允许，第 101 次阻止。
- 请求提交即计数，失败和超时不返还；应用不自动重试。
- 账号用量查询失败时停止，不冒险提交完整截图。
- 完整截图固定发送到火山官方 HTTPS 域名，不使用可编辑的文字翻译 Endpoint。
- 原截图立即显示，整图结果只保留在当前窗口内存中，除非用户主动保存。
- 火山失败时不静默上传到其他服务，也不自动降级；用户可手动选择 Apple 本地坐标翻译。

### Apple 本地坐标翻译

Apple 本地链路默认使用 `Option + W`，并可在设置中修改。它使用 Apple Vision OCR + Swift 版 OCR layout engine，也可从菜单栏或火山结果窗口手动进入。

数据流：

```text
ScreenshotCaptureController
-> OCRService.recognizeOverlaySnapshot(.accurate)
-> AppleOCRLayoutEngine
-> OCRLayoutBand / OCRLayoutSection
-> ImageOverlayTranslationWindowController 立即显示冻结截图
-> Apple TranslationSession 本地批量翻译（macOS 15+）
-> macOS 13–14 使用 TranslationService 云端兼容路径
-> OverlayCanvasView 实时绘制
-> ScreenshotTranslationOverlayRenderer 导出图片
```

本地链路的核心目标是：

- OCR 负责识别文字和定位。
- `AppleOCRLayoutEngine` 负责把 Vision observation 按 band、列、section 合并成自然翻译区域。
- 翻译单位是 `OverlaySegment`，不是单个 OCR block。
- 覆盖擦除单位是 `eraseBoxes`，优先贴近原文字区域。
- 截图后立即展示冻结原图并自动开始 OCR 和翻译。
- macOS 15 及以上优先使用 Apple 设备端翻译；macOS 26.4 及以上选择 `lowLatency` 策略。
- 首次使用某个语言组合时由 macOS 请求一次离线语言包下载许可；之后不需要确认，也不产生 API 费用。
- 本地翻译连续 12 秒没有结果就停止加载，每返回一段译文会重新计时；语言包仍未就绪时提示用户先在系统设置完成下载，避免覆盖窗口无限转圈。
- macOS 15 及以上不会在本地失败或用户取消下载后静默上传文字；错误保留在当前覆盖窗口。
- macOS 13–14 的云端兼容路径最多同时处理两批，任一批完成后立即回填。
- `nativeReplace` 尝试先擦除原文，再按原位回填译文。
- 火山图片翻译和坐标翻译产生的应用临时截图与 overlay debug 目录保留 3 天后自动清理；用户手动保存的 PNG 不受影响。

## 关键数据结构

### OCRTextBlock

`OCRTextBlock` 是 Apple Vision OCR observation 级别的识别结果。它仍然保留在项目中，用于普通 OCR、兼容逻辑和 debug，但不再是截图覆盖翻译的核心翻译单位。

### OCRLayoutObservation / OCRLayoutSection

`OCRLayoutObservation` 是覆盖翻译中的 Vision observation 级文本单元，坐标已经映射到原图 pixel 坐标。

`OCRLayoutSection` 是截图覆盖翻译的核心布局单位：

- 一个标题、自然段、列表项或标签通常应对应一个 section。
- section 内保留 `TextLine` 行骨架，供翻译和回填使用。
- section 会生成最终的 `OverlaySegment`。

`TextAtom` 现在只作为 `TextLine` 的轻量兼容载体使用，不再通过 `VNRecognizedText.boundingBox(for:)` 做词级主分块。

### TextLine

`TextLine` 表示一行文字，由多个 `TextAtom` 合并得到。

作用：

- 保留原图中的行结构。
- 为截图覆盖翻译提供“按 OCR 行骨架翻译”的依据。
- 为 `nativeReplace` 提供逐行回填区域。

### OverlaySegment

`OverlaySegment` 是截图覆盖翻译的翻译单位。

它包含：

- `sourceText`：用于整体语义翻译。
- `lines`：保留原始 OCR 行骨架。
- `boundingBox`：翻译排版的大致区域。
- `lineBoxes`：逐行区域。
- `eraseBoxes`：擦除原文的区域。
- `role`：`title / paragraph / button / label / tableCell / caption / code / url / number / unknown`。
- `shouldTranslate`：控制 URL、代码、数字等是否跳过翻译。

## OCR 与坐标

截图覆盖翻译使用 `OCRService.recognizeOverlaySnapshot(from:displayPointSize:mode:)`。

当前 OCR 处理包含这些点：

- 使用 Apple Vision 本地 OCR。
- 覆盖翻译默认使用 `.accurate`。
- 保留 Retina 原始像素。
- 区分 `displayPointSize`、`originalImageSize`、`ocrImageSize`、`backingScaleFactor`、`ocrScaleFactor` 和 `coordinateSpace`。
- 当有效缩放不足时，会对 OCR 输入图做高质量放大。
- OCR 输出坐标统一转成原图 pixel 坐标。

理解定位问题时，优先看：

- `OCRService.prepareImage`
- `OCRService.imagePixelRect`
- `OCRService.mappedOriginalPixelRect`
- `OCRTextBoxDebugInfo`

## 本地 layout 分块

本地分块由 `AppleOCRLayoutEngine` 组织：

```text
Vision observations
-> horizontal bands
-> columns
-> layout lines
-> OCRLayoutSection
-> OverlaySegment
```

分块原则：

- 先稳定构造行，再判断多行是否属于同一语义段。
- 一整句、一段说明、同一个气泡或同一个标题应尽量合成一个 `OverlaySegment`。
- 按钮、菜单项、表格单元格、列表项应避免错误合并。
- URL、代码、版本号、纯数字、金额等标记为对应 role，并尽量 `shouldTranslate=false`。

如果出现“一行几个词被拆开翻译”，优先看：

- `AppleOCRLayoutEngine.buildLines`
- `AppleOCRLayoutEngine.belongsOnSameLine`
- `AppleOCRLayoutEngine.shouldMerge`

如果出现“不同段被合在一起”，优先看：

- `AppleOCRLayoutEngine.buildBands`
- `AppleOCRLayoutEngine.detectColumns`
- `AppleOCRLayoutEngine.shouldMerge`

## 行骨架翻译

截图覆盖翻译现在不是只让模型返回整段译文，而是让模型尽量按 OCR 行骨架返回。

Apple 本地翻译返回语义段译文后，本地会按同一套 OCR 行骨架做比例切分并回填。云端 Prompt provider 仍可直接返回结构化 `lineTranslations`。

输入给模型的是：

- `segment.id`
- `segment.role`
- `segment.sourceText`
- `segment.readingOrder`
- `segment.lines[]`

期望模型返回：

```json
{
  "translations": [
    {
      "id": "segment-id",
      "translation": "整段译文",
      "lineTranslations": [
        {
          "lineIndex": 0,
          "translation": "第 1 行译文"
        }
      ]
    }
  ]
}
```

解析与 fallback 顺序：

1. 优先使用结构化 `lineTranslations`。
2. 如果缺行、空行或索引异常，回退到整段 `translation`。
3. 如果只有整段译文，本地按原 OCR 行骨架做启发式切分。
4. 如果翻译失败，保留原文，不让整张图失败。

重点看：

- `PromptBuilder.buildImageOverlayBatchPrompt`
- `ImageOverlayBatchTranslator.parseBatchResponse`
- `ImageOverlayBatchTranslator.validatedLineTranslations`
- `ImageOverlayBatchTranslator.splitTranslationByLineSkeleton`

## 覆盖渲染

覆盖窗口的实时预览由 `OverlayCanvasView` / `OverlayRegionPainter` 负责；复制图片、保存 PNG 和 debug 的最终导出仍由 `ScreenshotTranslationOverlayRenderer` 负责。

样式：

- `nativeReplace`

当前会话式覆盖翻译只把 `nativeReplace` 作为默认主路径。

`nativeReplace` 的目标：

- 先用 `eraseBoxes` 擦除原文字。
- 背景色从周边采样。
- 复杂背景时用半透明遮罩保证可读性。
- 优先按 `lineTranslations + lineBoxes` 逐行回填。
- 如果逐行回填失败，再回退到整段排版。

如果出现“译文仍然像白块贴上去”，优先看：

- `ScreenshotTranslationOverlayRenderer.renderNativeReplaceSegment`
- `ScreenshotTranslationOverlayRenderer.renderLineAlignedNativeReplaceSegment`
- `ScreenshotTranslationOverlayRenderer.perLineTextRect`
- `ScreenshotTranslationOverlayRenderer.relaxedPerLineTextRect`
- `ScreenshotTranslationOverlayRenderer.drawNativeReplaceBackground`

## Debug 输出

打开 debug：

```sh
TTS_DEBUG_OVERLAY_PIPELINE=1 swift run
```

或者设置 `UserDefaults` 的 `debugOverlayPipeline = true`。

开启后会输出到临时目录：

- `original.png`
- `ocr_input.png`
- `ocr_boxes.png`
- `layout_bands.png`
- `layout_sections.png`
- `text_lines.png`
- `overlay_segments.png`
- `display_regions.png`
- `erase_preview.png`
- `translated_live.png`
- `final_overlay.png`
- `debug_report.json`

看问题时建议按这个顺序：

1. `ocr_boxes.png`：OCR 是否定位到主要文字。
2. `layout_bands.png`：横向 band 是否把版面切到合理层级。
3. `layout_sections.png`：标题、段落、列表项是否合并为自然区域。
4. `text_lines.png`：一整行是否被正确合并。
5. `overlay_segments.png`：翻译单位是否合理。
6. `display_regions.png`：会话窗口用于绘制的区域状态是否正确。
7. `erase_preview.png`：原文擦除区域是否贴近原字。
8. `translated_live.png`：实时 canvas 效果是否自然。
9. `final_overlay.png`：导出图片最终回填是否自然。

`debug_report.json` 中重点看：

- `ocrObservationCount`
- `textAtomCount`
- `textLineCount`
- `overlaySegmentCount`
- `averageLinesPerSegment`
- `singleLineSegmentRatio`
- `eraseBoxCount`
- `scaleFactor`
- `ocrScaleFactor`
- `originalImageSize`
- `ocrImageSize`
- `boxDebugInfo`

## 当前路线边界

当前产品决策是：

- `Option + W` 默认使用 Apple 本地坐标翻译；macOS 15 及以上不把 OCR 文字交给已配置的第三方翻译服务，macOS 13–14 使用默认服务兼容翻译。
- API 高质量坐标翻译与火山图片翻译各有独立快捷键槽，可在设置中录制或清除。
- API 与 Apple 两条坐标翻译路径都不让远端 Vision 模型生成坐标。
- 坐标翻译的 OCR 与定位只由 Apple Vision 和本地算法负责。
- 火山失败不自动重试，也不静默切换其他云服务或本地链路。

这样可以保留本地坐标稳定性，同时让用户按需选择默认 API 的翻译质量或火山整图能力。

## 维护判断

截图覆盖翻译问题通常可以按以下方式定位：

- 文字识别错：看 `OCRService` 和 OCR debug 图。
- 坐标偏：看 `ocr_boxes.png` 和 `boxDebugInfo`。
- 一句话被拆碎：看 `AppleOCRLayoutEngine` 的行合并和 section 合并。
- 不同段误合并：看 `AppleOCRLayoutEngine` 的 band、column 和 `shouldMerge` 规则。
- 翻译行数不稳：看 `PromptBuilder` 和 `ImageOverlayBatchTranslator` 的 `lineTranslations` 解析。
- 白块感明显：看 `ScreenshotTranslationOverlayRenderer` 的 `nativeReplace` 擦除和逐行绘制逻辑。
- 火山主路径速度慢：先区分本地图片编码与单次 `TranslateImage` 网络耗时。
- 坐标翻译速度慢：看日志中的 `ocr / segmentation / translation` 阶段耗时。
