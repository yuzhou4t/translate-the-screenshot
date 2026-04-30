# 截图翻译实现说明

本文档用于理解 TTS 的截图翻译、截图 OCR 和截图覆盖翻译。它按当前代码状态书写，优先解释本地 OCR、文本分块、批量翻译和覆盖渲染之间的关系。

## 先看什么

如果只想理解产品和当前能力，先看：

- [README.md](../README.md)：项目入口、快捷键、能力范围和构建方式。
- [CHANGELOG.md](CHANGELOG.md)：最近为什么这样改，特别是截图覆盖翻译从 OCR block 到本地语义分块、行骨架翻译和 `nativeReplace` 的演进。
- [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md)：产品边界，尤其是“轻量、快速、原生 macOS、不做复杂视觉模型路由”。
- [DIFFERENTIATION.md](DIFFERENTIATION.md)：TTS 和 Bob / Easydict 的差异，帮助判断截图翻译相关功能是否符合项目方向。

如果要理解截图覆盖翻译实现，建议按这个顺序读代码：

1. `Sources/TTS/Screenshot/ScreenshotCaptureController.swift`
2. `Sources/TTS/OCR/OCRService.swift`
3. `Sources/TTS/OCR/AppleOCRLayoutEngine.swift`
4. `Sources/TTS/Screenshot/TextAtom.swift`
5. `Sources/TTS/Screenshot/ImageOverlaySession.swift`
6. `Sources/TTS/Screenshot/ImageOverlayTranslationWindow.swift`
7. `Sources/TTS/Screenshot/ImageOverlayBatchTranslator.swift`
8. `Sources/TTS/App/PromptBuilder.swift`
9. `Sources/TTS/Screenshot/ScreenshotTranslationOverlayRenderer.swift`
10. `Sources/TTS/Screenshot/OverlayPipelineDebugWriter.swift`

## 三条截图相关链路

### 普通截图翻译

普通截图翻译的目标是得到一段可读译文，不需要图片覆盖。

数据流：

```text
ScreenshotCaptureController
-> OCRService.recognizeText
-> OCRTextPostProcessor
-> TranslationService.translate(scenario: .screenshot)
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

### 截图覆盖翻译

截图覆盖翻译是单独链路，不再使用 Gemini / OpenAI Vision 做视觉分块。当前主路径是本地 Apple Vision OCR + Swift 版 OCR layout engine。

数据流：

```text
ScreenshotCaptureController
-> OCRService.recognizeOverlaySnapshot(.accurate)
-> AppleOCRLayoutEngine
-> OCRLayoutBand / OCRLayoutSection
-> ImageOverlayTranslationWindowController
-> TranslationService.translateImageOverlaySegmentsIncrementally
-> ImageOverlayBatchTranslator
-> OverlayCanvasView 实时绘制
-> ScreenshotTranslationOverlayRenderer 导出图片
```

这条链路的核心目标是：

- OCR 负责识别文字和定位。
- `AppleOCRLayoutEngine` 负责把 Vision observation 按 band、列、section 合并成自然翻译区域。
- 翻译单位是 `OverlaySegment`，不是单个 OCR block。
- 覆盖擦除单位是 `eraseBoxes`，优先贴近原文字区域。
- 截图后先展示 OCR 覆盖框，用户点击翻译后按批次原位回填译文。
- `nativeReplace` 尝试先擦除原文，再按原位回填译文。

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
- `usedVisionModel`
- `scaleFactor`
- `ocrScaleFactor`
- `originalImageSize`
- `ocrImageSize`
- `boxDebugInfo`

`usedVisionModel` 在当前主链路中应为 `false`。

## 当前不走的路线

当前产品决策是：

- 不让 Gemini / OpenAI Vision 参与截图版面分块。
- 不让大模型生成坐标。
- 不让视觉模型生成图片。
- OCR 与定位只由本地 Apple Vision 和本地算法负责。

这符合项目当前的轻量化方向：速度优先、成本可控、失败路径简单。

## 维护判断

截图覆盖翻译问题通常可以按以下方式定位：

- 文字识别错：看 `OCRService` 和 OCR debug 图。
- 坐标偏：看 `ocr_boxes.png` 和 `boxDebugInfo`。
- 一句话被拆碎：看 `AppleOCRLayoutEngine` 的行合并和 section 合并。
- 不同段误合并：看 `AppleOCRLayoutEngine` 的 band、column 和 `shouldMerge` 规则。
- 翻译行数不稳：看 `PromptBuilder` 和 `ImageOverlayBatchTranslator` 的 `lineTranslations` 解析。
- 白块感明显：看 `ScreenshotTranslationOverlayRenderer` 的 `nativeReplace` 擦除和逐行绘制逻辑。
- 速度慢：先看日志中的 `ocr / segmentation / translation` 阶段耗时，通常远端翻译服务比本地 OCR 更容易成为瓶颈。
