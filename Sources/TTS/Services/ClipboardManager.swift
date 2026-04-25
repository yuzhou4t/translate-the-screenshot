import AppKit

enum ClipboardManagerError: LocalizedError {
    case copyTimedOut
    case noTextCopied

    var errorDescription: String? {
        switch self {
        case .copyTimedOut:
            "无法从剪贴板读取选中文字。"
        case .noTextCopied:
            "当前选择没有复制到文本。"
        }
    }
}

@MainActor
final class ClipboardManager {
    private struct PasteboardItemSnapshot {
        var values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    func readTextByCopyingSelection() async throws -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = makeSnapshot(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount

        defer {
            restore(snapshot, to: pasteboard)
        }

        simulateCommandC()

        let deadline = Date().addingTimeInterval(0.8)
        while pasteboard.changeCount == previousChangeCount && Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        guard pasteboard.changeCount != previousChangeCount else {
            throw ClipboardManagerError.copyTimedOut
        }

        guard let copiedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !copiedText.isEmpty else {
            throw ClipboardManagerError.noTextCopied
        }

        return copiedText
    }

    private func makeSnapshot(from pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        pasteboard.pasteboardItems?.map { item in
            let values = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }
            return PasteboardItemSnapshot(values: values)
        } ?? []
    }

    private func restore(_ snapshot: [PasteboardItemSnapshot], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let restoredItems = snapshot.map { snapshotItem in
            let item = NSPasteboardItem()
            for value in snapshotItem.values {
                item.setData(value.data, forType: value.type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }

    private func simulateCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCodeC: CGKeyCode = 8

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
