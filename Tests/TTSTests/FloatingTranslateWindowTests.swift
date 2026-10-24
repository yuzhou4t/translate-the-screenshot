#if canImport(Testing)
@testable import TTS
import AppKit
import Testing

@Suite("Floating translation window")
struct FloatingTranslateWindowTests {
    @Test("Title press delegates borderless panel dragging to AppKit")
    @MainActor
    func titleDrag() throws {
        let panel = FloatingTranslateWindow(
            contentRect: NSRect(x: 100, y: 100, width: 560, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let event = try mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 500), in: panel)
        var nativeDragEvent: NSEvent?
        panel.nativeDragHandlerForTesting = { nativeDragEvent = $0 }

        #expect(panel.shouldBeginWindowDrag(for: event))
        panel.sendEvent(event)
        #expect(nativeDragEvent === event)
    }

    @Test("Interactive controls remain outside the native title drag area")
    @MainActor
    func controlsRemainInteractive() throws {
        let panel = FloatingTranslateWindow(
            contentRect: NSRect(x: 100, y: 100, width: 560, height: 540),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let pinButtonEvent = try mouseEvent(
            .leftMouseDown,
            at: NSPoint(x: 530, y: 500),
            in: panel
        )

        #expect(!panel.shouldBeginWindowDrag(for: pinButtonEvent))
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in panel: NSPanel
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
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
