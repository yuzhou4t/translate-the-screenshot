import Foundation

struct PromptBuilder {
    struct Prompt {
        var system: String
        var user: String
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
                Translate the text into the target language with wording that is as concise as possible while preserving the intended meaning.
                The result should fit back into the original image text region, so prefer shorter natural phrasing when possible.
                Do not explain, annotate, add notes, add prefixes, or include alternatives.
                Preserve numbers, units, brand names, product names, code, identifiers, URLs, and other text that should remain unchanged.
                Return only the translated text.
                """,
                user: """
                Translate the following text into \(targetLanguage) for image overlay use.
                Keep it short, clear, and suitable for placing back into the original image area.

                <source_text>
                \(sourceText)
                </source_text>
                """
            )
        }
    }
}
