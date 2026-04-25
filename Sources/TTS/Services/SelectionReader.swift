import ApplicationServices
import Foundation

enum SelectionReaderError: LocalizedError {
    case accessibilityPermissionMissing
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "需要辅助功能权限才能读取选中文字。"
        case .emptySelection:
            "请先选中一段文字，再按快捷键。"
        }
    }
}

@MainActor
final class SelectionReader {
    private let clipboardManager: ClipboardManager
    private let permissionManager: PermissionManager

    init(clipboardManager: ClipboardManager, permissionManager: PermissionManager) {
        self.clipboardManager = clipboardManager
        self.permissionManager = permissionManager
    }

    func readSelectedText() async throws -> String {
        let hasAccessibilityPermission = permissionManager.isAccessibilityTrusted

        if hasAccessibilityPermission,
           let selectedText = readWithAccessibility(),
           !selectedText.isEmpty {
            return selectedText
        }

        if !hasAccessibilityPermission {
            permissionManager.openAccessibilityPromptIfNeeded()
        }

        let copiedText: String
        do {
            copiedText = try await clipboardManager.readTextByCopyingSelection()
        } catch {
            if !hasAccessibilityPermission {
                throw SelectionReaderError.accessibilityPermissionMissing
            }
            throw error
        }

        guard !copiedText.isEmpty else {
            throw SelectionReaderError.emptySelection
        }

        return copiedText
    }

    private func readWithAccessibility() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedResult == .success,
              let focusedElement = focusedObject else {
            return nil
        }

        var selectedTextObject: AnyObject?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextObject
        )

        guard selectedTextResult == .success,
              let selectedText = selectedTextObject as? String else {
            return nil
        }

        return selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
