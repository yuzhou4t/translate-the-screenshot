@testable import TTS
import Foundation

func checkMyMemoryBatchPayloadsRespectUTF8LimitAndStableIDs() {
    let items = [
        IdentifiedTranslationText(id: "heading", text: "Translate screenshots"),
        IdentifiedTranslationText(id: "body", text: "把整张图片翻译出来 👋")
    ]

    guard let payload = MyMemoryProvider.makeBatchPayloads(from: items).only else {
        preconditionFailure("expected one MyMemory batch payload")
    }
    precondition(Data(payload.query.utf8).count <= MyMemoryProvider.maximumTextBytes)
    precondition(payload.entries.map(\.id) == ["heading", "body"])

    let translatedResponse = """
    [[TTSB1]]
    Translate the whole image
    [[/TTSB1]]
    [[TTSB0]]
    Screenshot Translation
    [[/TTSB0]]
    """
    let results = MyMemoryProvider.parseBatchTranslation(
        translatedResponse,
        payload: payload
    )

    precondition(results == [
        IdentifiedTranslationTextResult(id: "heading", translatedText: "Screenshot Translation"),
        IdentifiedTranslationTextResult(id: "body", translatedText: "Translate the whole image")
    ])
}

func checkMyMemoryBatchPayloadsUseBytesAndLeaveOversizedOrReservedTextForFallback() {
    let exactASCII = String(repeating: "a", count: 479)
    let oversizedASCII = String(repeating: "b", count: 480)
    let fittingCJK = String(repeating: "译", count: 159)
    let oversizedCJK = String(repeating: "译", count: 160)
    let fittingEmoji = String(repeating: "👋", count: 119)
    let oversizedEmoji = String(repeating: "👋", count: 120)

    let payloads = MyMemoryProvider.makeBatchPayloads(from: [
        IdentifiedTranslationText(id: "ascii-exact", text: exactASCII),
        IdentifiedTranslationText(id: "ascii-too-large", text: oversizedASCII),
        IdentifiedTranslationText(id: "cjk-fitting", text: fittingCJK),
        IdentifiedTranslationText(id: "cjk-too-large", text: oversizedCJK),
        IdentifiedTranslationText(id: "emoji-fitting", text: fittingEmoji),
        IdentifiedTranslationText(id: "emoji-too-large", text: oversizedEmoji),
        IdentifiedTranslationText(id: "reserved-open", text: "unsafe [[TTSB0]] text"),
        IdentifiedTranslationText(id: "reserved-close", text: "unsafe [[/TTSB0]] text")
    ])

    let includedIDs = payloads.flatMap(\.entries).map(\.id)
    precondition(includedIDs == ["ascii-exact", "cjk-fitting", "emoji-fitting"])
    precondition(payloads.allSatisfy { Data($0.query.utf8).count <= MyMemoryProvider.maximumTextBytes })
    precondition(Data(payloads[0].query.utf8).count == MyMemoryProvider.maximumTextBytes)
}

func checkMyMemoryBatchParserReturnsOnlyWellFormedPairs() {
    guard let payload = MyMemoryProvider.makeBatchPayloads(from: [
            IdentifiedTranslationText(id: "first", text: "First"),
            IdentifiedTranslationText(id: "second", text: "Second")
        ]).only else {
        preconditionFailure("expected one MyMemory parser fixture payload")
    }

    let partialResponse = """
    [[TTSB0]]
    第一
    [[/TTSB0]]
    [[TTSB1]]
    第二
    """
    precondition(
        MyMemoryProvider.parseBatchTranslation(partialResponse, payload: payload) == [
            IdentifiedTranslationTextResult(id: "first", translatedText: "第一")
        ]
    )

    let duplicateMarkerResponse = """
    [[TTSB0]]
    第一
    [[TTSB0]]
    第一重复
    [[/TTSB0]]
    [[TTSB1]]
    第二
    [[/TTSB1]]
    """
    precondition(
        MyMemoryProvider.parseBatchTranslation(duplicateMarkerResponse, payload: payload) == [
            IdentifiedTranslationTextResult(id: "second", translatedText: "第二")
        ]
    )
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
