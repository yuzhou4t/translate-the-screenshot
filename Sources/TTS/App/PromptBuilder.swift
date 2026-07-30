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
}
