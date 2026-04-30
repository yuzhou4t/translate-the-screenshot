@testable import TTS
import CoreGraphics
import Foundation

private let _runAppleOCRLayoutEngineRegressionChecks: Void = {
    checkWechatBookSpreadKeepsLocalDiagramLabelsSeparate()
    checkDetachedSameBaselinePhrasesDoNotMergeAcrossDiagramCallouts()
}()

private func checkWechatBookSpreadKeepsLocalDiagramLabelsSeparate() {
    let engine = AppleOCRLayoutEngine()
    let imageSize = CGSize(width: 1600, height: 800)
    let snapshot = engine.buildSnapshot(
        from: [
            block("时间循环", x: 400, y: 70, width: 260, height: 48),
            block("如果循环的守护者或咒语作者", x: 280, y: 150, width: 420, height: 32),
            block("死亡，一天将从头开始重复。", x: 305, y: 190, width: 390, height: 32),
            block("来自守护者的物品", x: 430, y: 286, width: 150, height: 22),
            block("向日葵，我与塞", x: 610, y: 285, width: 170, height: 30),
            block("西莉亚种植的", x: 610, y: 322, width: 150, height: 30),
            block("千年椒树的枝条", x: 170, y: 360, width: 190, height: 26),
            block("千年古树", x: 275, y: 455, width: 120, height: 26),
            block("1) 将物品放在祭坛", x: 960, y: 40, width: 300, height: 36),
            block("上。", x: 965, y: 82, width: 70, height: 34),
            block("2) 让那些应该意识到循环", x: 960, y: 155, width: 420, height: 36),
            block("的存在的人留在祭坛上。", x: 960, y: 198, width: 390, height: 36),
            block("3) 说咒语：", x: 960, y: 325, width: 220, height: 36),
            block("“让时间循环！”", x: 985, y: 375, width: 250, height: 36),
            block("你可以通过再次施放这个", x: 970, y: 520, width: 390, height: 38),
            block("咒语来停止循环。", x: 970, y: 566, width: 310, height: 38)
        ],
        imageSize: imageSize
    )

    let segments = snapshot.segmentation.overlaySegments
    let leftSegments = segments.filter { $0.boundingBox.midX < imageSize.width * 0.5 }
    let rightSegments = segments.filter { $0.boundingBox.midX > imageSize.width * 0.5 }

    precondition(!leftSegments.isEmpty, "expected left-page segments")
    precondition(!rightSegments.isEmpty, "expected right-page segments")
    precondition(!segments.contains { segment in
        segment.boundingBox.minX < imageSize.width * 0.5 && segment.boundingBox.maxX > imageSize.width * 0.5
    }, "segments must not cross the page gutter")
    precondition(segments.contains { $0.sourceText.contains("1)") }, "expected list item 1 segment")
    precondition(segments.contains { $0.sourceText.contains("2)") }, "expected list item 2 segment")
    precondition(segments.contains { $0.sourceText.contains("3)") }, "expected list item 3 segment")
    precondition(!segments.contains { $0.sourceText.contains("千年椒树") && $0.sourceText.contains("时间循环") }, "short labels must not merge into title/body text")
    precondition(!segments.contains { $0.sourceText.contains("来自守护者") && $0.sourceText.contains("向日葵") }, "nearby inline label must not merge with sunflower box")
    precondition(segments.contains { $0.sourceText.contains("向日葵") && $0.sourceText.contains("西莉亚") && $0.reflowPreferred }, "sunflower box should be its own bounded reflow segment")
    precondition(segments.filter(\.reflowPreferred).count >= 3, "long body/list sections should prefer reflow")
}

private func checkDetachedSameBaselinePhrasesDoNotMergeAcrossDiagramCallouts() {
    let engine = AppleOCRLayoutEngine()
    let snapshot = engine.buildSnapshot(
        from: [
            block("An item from", x: 405, y: 290, width: 132, height: 20),
            block("the guardian", x: 540, y: 290, width: 120, height: 20),
            block("Sunflower me and", x: 690, y: 288, width: 170, height: 28),
            block("Cecilia planted", x: 690, y: 320, width: 145, height: 28)
        ],
        imageSize: CGSize(width: 1200, height: 700)
    )

    let segments = snapshot.segmentation.overlaySegments
    precondition(!segments.contains { $0.sourceText.contains("guardian") && $0.sourceText.contains("Sunflower") }, "guardian note must not merge into sunflower callout")
    precondition(segments.contains { $0.sourceText.contains("An item from") && $0.sourceText.contains("the guardian") }, "guardian note should remain a local phrase")
    precondition(segments.contains { $0.sourceText.contains("Sunflower") && $0.sourceText.contains("Cecilia") }, "sunflower callout should stay local")
}

private func block(
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
) -> OCRTextBlock {
    OCRTextBlock(
        id: UUID(),
        text: text,
        boundingBox: CGRect(x: x, y: y, width: width, height: height),
        confidence: 0.98
    )
}
