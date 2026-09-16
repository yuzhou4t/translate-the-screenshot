#if canImport(Testing)
@testable import TTS
import AppKit
import Testing

@Suite("Floating translation window")
struct FloatingTranslateWindowTests {
    @Test("Dragging the title moves the borderless panel in both axes")
    @MainActor
    func titleDrag() throws {
        let panel = FloatingTranslateWindow(
            contentRect: NSRect(x: 100, y: 100, width: 560, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.dragMouseLocationOverride = NSPoint(x: 300, y: 300)
        panel.sendEvent(try mouseEvent(.leftMouseDown, in: panel))

        panel.dragMouseLocationOverride = NSPoint(x: 340, y: 325)
        panel.sendEvent(try mouseEvent(.leftMouseDragged, in: panel))
        #expect(panel.frame.origin == NSPoint(x: 140, y: 125))

        panel.dragMouseLocationOverride = NSPoint(x: 275, y: 270)
        panel.sendEvent(try mouseEvent(.leftMouseDragged, in: panel))
        #expect(panel.frame.origin == NSPoint(x: 75, y: 70))

        panel.sendEvent(try mouseEvent(.leftMouseUp, in: panel))
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, in panel: NSPanel) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 100, y: 500),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
#endif
