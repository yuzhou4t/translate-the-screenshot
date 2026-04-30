import Foundation

struct PromptBuilder {
    struct Prompt {
        var system: String
        var user: String
    }

    struct ImageOverlayBatchSegment: Encodable {
        var id: String
        var role: String
        var sourceText: String
        var lines: [ImageOverlayBatchLine]
        var readingOrder: Int
    }

    struct ImageOverlayBatchLine: Encodable {
        var lineIndex: Int
        var text: String
    }

    struct VisionSegmentationOCRBlock: Encodable {
        struct BoundingBox: Encodable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
        }

        var id: String
        var text: String
        var boundingBox: BoundingBox
        var confidence: Double
    }

    static func build(
        mode: TranslationMode,
        sourceText: String,
        targetLanguage: String
    ) -> Prompt {
        switch mode {
        case .fast:
            Prompt(
                system: """
                You are a fast translation engine for short on-screen text.
                Translate into the target language with the fewest words that still preserve the core meaning.
                Return only the translation.
                Do not explain, annotate, quote the source, or add alternatives.
                """,
                user: """
                Translate the following text into \(targetLanguage).
                Keep it concise and direct.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .accurate:
            Prompt(
                system: """
                You are an accurate translation engine.
                Preserve the original meaning, tone, logic, qualifiers, negation, and information order.
                Do not add information, omit information, simplify nuanced statements, or rewrite the structure unless required by the target language.
                Return only the translation.
                """,
                user: """
                Translate the following text into \(targetLanguage) faithfully.
                Keep the tone and logical relationships intact.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .natural:
            Prompt(
                system: """
                You are a natural translation editor.
                Translate faithfully while making the result sound native, smooth, and idiomatic in the target language.
                Avoid mechanical literalism, but do not change the meaning, emphasis, or factual content.
                Return only the translation.
                """,
                user: """
                Translate the following text into natural, idiomatic \(targetLanguage).
                Keep the original meaning fully intact.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .academic:
            Prompt(
                system: """
                You are a senior academic translator for papers, reports, and policy texts.
                Use a formal, rigorous, non-colloquial register.
                Keep terminology stable and precise across the passage.
                Preserve qualifiers, scope limitations, causal relations, contrasts, concessions, and progressive arguments.
                Do not delete conditions, hedge words, evidence markers, citations, numbers, headings, or paragraph structure.
                Do not add interpretations beyond the source.
                Return only the translation.
                """,
                user: """
                Translate the following text into formal academic \(targetLanguage).
                Make it suitable for a paper, report, or policy document without losing nuance or logical structure.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .technical:
            Prompt(
                system: """
                You are a technical translation engine.
                Preserve fenced code blocks, inline code, variable names, API names, commands, URLs, file paths, version strings, log text, and proprietary technical identifiers exactly.
                Preserve Markdown structure, including headings, lists, tables, emphasis, links, and code fences.
                Translate natural-language prose around the technical content, but do not explain code, do not rewrite commands, and do not translate identifiers.
                If part of the source is already code or machine-readable text, keep it unchanged.
                Return only the translated result in the original Markdown-compatible structure.
                """,
                user: """
                Translate the following technical text into \(targetLanguage).
                Keep all code, commands, API names, identifiers, and Markdown formatting intact.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .ocrCleanup:
            Prompt(
                system: """
                You are an OCR cleanup engine, not a translator.
                Keep the original language.
                Repair obvious OCR errors, broken line wraps, paragraph structure, spacing, punctuation, and character confusion only when the intended text is clear from context.
                Do not translate, summarize, explain, or rewrite the meaning.
                Preserve numbers, dates, URLs, email addresses, code, product names, proper nouns, and technical identifiers.
                Return only the cleaned text.
                """,
                user: """
                Clean up the OCR text below.
                Preserve the original language and meaning.
                Do not translate it.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .bilingual:
            Prompt(
                system: """
                You are a bilingual translation engine.
                Always output both the original text and the translation.
                Do not omit any part of the source.
                Use the exact format below:

                Original:
                <original text>

                Translation (\(targetLanguage)):
                <translated text>
                """,
                user: """
                Create a bilingual result for the following text.
                Keep the original text complete, then provide the \(targetLanguage) translation.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .polished:
            Prompt(
                system: """
                You are a translation and polishing editor.
                First translate accurately, then polish the wording so it reads naturally and smoothly in the target language.
                Keep the original meaning, tone, and level of certainty.
                Do not over-rewrite, embellish, summarize, or add ideas not present in the source.
                Return only the polished translation.
                """,
                user: """
                Translate the following text into \(targetLanguage), then polish the phrasing moderately for clarity and flow.
                Keep the original meaning intact.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        case .imageOverlay:
            Prompt(
                system: """
                You are a translation engine for image overlay replacement.
                Translate the text into the target language with the shortest natural wording that still preserves the intended meaning.
                The result will be drawn back into the original image text region, so prioritize compact, stable phrasing.
                Do not explain, annotate, add notes, add prefixes such as "Translation:", or include alternatives.
                Do not expand short source text into longer sentences.
                For buttons, menus, labels, and UI text, prefer brief interface-style wording.
                For full sentences, keep the meaning accurate but compress the expression when possible.
                Preserve numbers, units, brand names, product names, code, identifiers, URLs, and necessary symbols.
                Avoid long sentences unless the source itself clearly requires them.
                Return only the translated text.
                """,
                user: """
                Translate the following text into \(targetLanguage) for image overlay use.
                Keep it short, clear, and suitable for placing back into the original image area.
                If the source is a short text block, keep the translation equally short.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        }
    }

    static func buildImageOverlayBatchPrompt(
        segments: [ImageOverlayBatchSegment],
        targetLanguage: String
    ) -> Prompt {
        let encodedSegments = (try? JSONEncoder().encode(segments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return Prompt(
            system: """
            You are translating screenshot overlay segments for direct in-image replacement.
            Each input item is one OverlaySegment from the same screenshot.
            Translate into \(targetLanguage) while preserving screenshot context, concise UI wording, and exact id alignment.

            Return ONLY valid JSON.
            Do not output Markdown.
            Do not output code fences.
            Do not output explanations.
            Do not output any text before or after the JSON.

            Output schema:
            {
              "translations": [
                {
                  "id": "seg_1",
                  "translation": "translated text",
                  "lineTranslations": [
                    {
                      "lineIndex": 0,
                      "translation": "line 1 translation"
                    }
                  ]
                }
              ]
            }

            Hard requirements:
            - Return exactly one translation object for every input segment id.
            - Do not omit any segment id.
            - Do not add any new segment id.
            - Do not merge multiple segments into one translation.
            - Do not split one segment into multiple translations.
            - Do not modify any id.
            - Keep segment boundaries unchanged.
            - Each segment includes its OCR line skeleton. For multi-line segments, return lineTranslations that preserve the original line count and line order whenever possible.
            - Do not collapse a 2-3 line segment into a single line unless it is absolutely impossible to avoid.
            - Do not expand one source line into many short fragments.
            - If a segment should stay unchanged, return the original sourceText as its translation.

            Role-specific style rules:
            - title: concise, title-like, clear.
            - paragraph: natural, complete, faithful, but not verbose.
            - button: short, action-oriented, UI-native wording.
            - label: short, label-like, no extra explanation.
            - tableCell: as short as possible without losing meaning.
            - caption: natural descriptive wording.
            - code: return unchanged.
            - url: return unchanged.
            - number: return unchanged.
            - unknown: translate normally, but do not expand.

            General translation rules:
            - Use role and readingOrder as context only; do not echo them.
            - Use lines as layout constraints, not as separate independent segments.
            - Preserve numbers, amounts, units, dates, version strings, proper nouns, URLs, code, commands, variable names, identifiers, brand names, and product names unless the target language normally requires a minimal form adjustment.
            - For button, label, and tableCell text, keep the result short.
            - For paragraph text, produce a natural full translation without dropping meaning.
            - Do not add parentheses explanations.
            - Do not add information that is not in the source.
            - Do not over-explain UI text.
            - Do not rewrite short UI text into long sentences.
            - For object labels and diagram captions, preserve the local noun phrase. If a line reads like "Sunflower, me and Cecilia planted", translate it as "the sunflower planted by me and Cecilia" in the target language; do not attach nearby labels such as "from the guardian" to it.
            - Prioritize fitting the translation back into the original screenshot layout.
            """
            ,
            user: """
            Translate the following OverlaySegment items into \(targetLanguage).
            The input already excludes segments that should definitely remain untranslated.
            Use role, readingOrder, and lines to improve wording consistency and preserve the original OCR line skeleton.
            For multi-line segments, keep the original line count whenever possible and return lineTranslations aligned by lineIndex.
            Return only JSON in the required schema.

            <input_segments_json>
            \(encodedSegments)
            </input_segments_json>
            """
        )
    }

    static func buildVisionSegmentationSystemPrompt() -> String {
        """
        你是截图翻译覆盖功能的版面分析器。

        你的任务：
        根据截图画面和 OCR block 列表，把碎片化 OCR block 合并为适合翻译和覆盖的自然语义段。

        核心规则：
        1. 不要逐个 OCR block 翻译。
        2. 对于明显属于同一行、同一段、同一气泡、同一说明文字、同一标题、同一按钮或同一完整标签的 OCR block，应积极合并为一个 segment。
        3. 一句话、一个标题、一个段落、一个按钮、一个完整标签，通常应该尽量只对应一个 segment。
        4. 只有在跨按钮、跨菜单项、跨表格单元格、跨列表项、或跨明显不同区域时，才不要合并。
        5. 保持自然阅读顺序。
        6. 不要改写 OCR 原文。
        7. 不要创造新的 block id。
        8. 坐标由本地程序根据 block id 计算，你只返回 block id。
        9. URL、邮箱、代码、命令、版本号、纯数字、金额、日期，通常不需要翻译，请设置 shouldTranslate=false，或设置合适 role。
        10. 如果一个 OCR block 是完整的独立 UI 文本，可以单独成为一个 segment。
        11. 如果多个 OCR block 组成一句完整话，必须合并为一个 segment。
        12. 如果多个 OCR block 在版面上明显属于同一语义单元，应优先合并；只有在边界明显不同时才保持分开。
        13. 只返回 JSON，不要 markdown，不要解释。

        输出 JSON 格式：
        {
          "segments": [
            {
              "id": "seg_1",
              "blockIDs": ["ocr_block_id_1", "ocr_block_id_2"],
              "sourceText": "合并后的原文",
              "role": "paragraph",
              "readingOrder": 1,
              "shouldTranslate": true
            }
          ]
        }

        role 只能使用：
        title
        paragraph
        button
        label
        tableCell
        caption
        code
        url
        number
        unknown
        """
    }

    static func buildVisionSegmentationUserPrompt(
        ocrBlocks: [VisionSegmentationOCRBlock],
        targetLanguage: String
    ) -> String {
        let encodedBlocks = (try? JSONEncoder().encode(ocrBlocks))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return """
        最终这些 segment 会被翻译成 \(targetLanguage) 并覆盖回截图原图。
        请结合截图画面和下方 OCR block 列表，返回适合翻译覆盖的语义段合并方案。

        <ocr_blocks_json>
        \(encodedBlocks)
        </ocr_blocks_json>
        """
    }
}
