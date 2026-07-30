import AppKit
import Carbon
import SwiftUI

public enum KeyboardShortcuts {
    public struct Name: Hashable, Sendable {
        public let rawValue: String
        public let initial: Shortcut?

        public init(_ rawValue: String, initial: Shortcut? = nil) {
            self.rawValue = rawValue
            self.initial = initial
        }
    }

    public struct Key: Codable, Hashable, Sendable {
        public let keyCode: UInt16
        public let display: String

        public init(keyCode: UInt16, display: String) {
            self.keyCode = keyCode
            self.display = display
        }

        public static let a = Key(keyCode: 0, display: "A")
        public static let s = Key(keyCode: 1, display: "S")
        public static let d = Key(keyCode: 2, display: "D")
        public static let c = Key(keyCode: 8, display: "C")
        public static let w = Key(keyCode: 13, display: "W")

        static func fromEventKeyCode(_ keyCode: UInt16) -> Key? {
            switch keyCode {
            case 0: .a
            case 1: .s
            case 2: .d
            case 8: .c
            case 13: .w
            default: nil
            }
        }
    }

    public struct Shortcut: Codable, Hashable, Sendable {
        public let key: Key
        public let modifierRawValue: UInt

        public init(_ key: Key, modifiers: NSEvent.ModifierFlags) {
            self.key = key
            modifierRawValue = modifiers.normalizedShortcutRawValue
        }

        var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifierRawValue)
        }

        var displayValue: String {
            "\(modifierFlags.shortcutDisplay)\(key.display)"
        }

        var carbonModifiers: UInt32 {
            var result: UInt32 = 0
            if modifierFlags.contains(.command) {
                result |= UInt32(cmdKey)
            }
            if modifierFlags.contains(.option) {
                result |= UInt32(optionKey)
            }
            if modifierFlags.contains(.control) {
                result |= UInt32(controlKey)
            }
            if modifierFlags.contains(.shift) {
                result |= UInt32(shiftKey)
            }
            return result
        }
    }

    public struct RegistrationError: LocalizedError, Equatable, Sendable {
        public let message: String

        public var errorDescription: String? {
            message
        }
    }

    @MainActor
    public static func onKeyUp(for name: Name, action: @escaping @MainActor () -> Void) {
        HotKeyCenter.shared.register(name: name, action: action)
    }

    @MainActor
    static func shortcut(for name: Name) -> Shortcut? {
        HotKeyCenter.shared.shortcut(for: name)
    }

    @MainActor
    @discardableResult
    static func setShortcut(_ shortcut: Shortcut?, for name: Name) -> RegistrationError? {
        HotKeyCenter.shared.setShortcut(shortcut, for: name)
    }

    @MainActor
    static func registrationError(for name: Name) -> RegistrationError? {
        HotKeyCenter.shared.registrationError(for: name)
    }
}

extension KeyboardShortcuts {
    @MainActor
    public struct Recorder: View {
        private let title: String
        private let name: Name
        @State private var shortcut: Shortcut?
        @State private var registrationError: RegistrationError?
        @State private var isRecording = false
        @State private var monitor: Any?

        public init(_ title: String, name: Name) {
            self.title = title
            self.name = name
            _shortcut = State(initialValue: KeyboardShortcuts.shortcut(for: name))
            _registrationError = State(initialValue: KeyboardShortcuts.registrationError(for: name))
        }

        public var body: some View {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Text(title)
                    Spacer()
                    Button(isRecording ? "请按快捷键" : (shortcut?.displayValue ?? "录制")) {
                        beginRecording()
                    }
                    .frame(minWidth: 130)
                    .onDisappear {
                        stopRecording()
                    }

                    Button("清除") {
                        updateShortcut(nil)
                    }
                    .disabled(shortcut == nil)
                }

                if let registrationError {
                    Text(registrationError.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func beginRecording() {
            stopRecording()
            isRecording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard isRecording else {
                    return event
                }

                guard let key = Key.fromEventKeyCode(event.keyCode) else {
                    NSSound.beep()
                    return nil
                }

                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !modifiers.isEmpty else {
                    NSSound.beep()
                    return nil
                }

                updateShortcut(Shortcut(key, modifiers: modifiers))
                stopRecording()
                return nil
            }
        }

        private func stopRecording() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            isRecording = false
        }

        private func updateShortcut(_ next: Shortcut?) {
            registrationError = KeyboardShortcuts.setShortcut(next, for: name)
            shortcut = registrationError == nil
                ? next
                : KeyboardShortcuts.shortcut(for: name)
            if registrationError != nil {
                NSSound.beep()
            }
        }
    }
}

@MainActor
private final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [KeyboardShortcuts.Name: @MainActor () -> Void] = [:]
    private var hotKeyRefs: [KeyboardShortcuts.Name: EventHotKeyRef] = [:]
    private var idsToNames: [UInt32: KeyboardShortcuts.Name] = [:]
    private var registrationErrors: [KeyboardShortcuts.Name: KeyboardShortcuts.RegistrationError] = [:]
    private var installedHandler: EventHandlerRef?
    private let signature = OSType(0x5454_5348)
    private let userDefaults = UserDefaults.standard

    private init() {}

    func register(name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        actions[name] = action
        installHandlerIfNeeded()
        let error = registerCarbonHotKey(for: name)
        registrationErrors[name] = error
        if let error {
            print("keyboard shortcut registration failed: \(name.rawValue): \(error.localizedDescription)")
        }
    }

    func shortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        let key = storageKey(for: name)
        if userDefaults.bool(forKey: disabledStorageKey(for: name)) {
            return nil
        }
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data) {
            return decoded
        }
        return name.initial
    }

    func setShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationError? {
        let previousShortcut = self.shortcut(for: name)

        guard let shortcut else {
            unregisterCarbonHotKey(for: name)
            persistShortcut(nil, for: name)
            registrationErrors[name] = nil
            return nil
        }

        if let error = internalConflictError(for: shortcut, excluding: name) {
            registrationErrors[name] = error
            return error
        }

        unregisterCarbonHotKey(for: name)
        let error = registerCarbonHotKey(shortcut, for: name)
        if let error {
            if let previousShortcut {
                let restorationError = registerCarbonHotKey(previousShortcut, for: name)
                if let restorationError {
                    print(
                        "keyboard shortcut restoration failed: \(name.rawValue): \(restorationError.localizedDescription)"
                    )
                }
            }
            registrationErrors[name] = error
            return error
        }

        persistShortcut(shortcut, for: name)
        registrationErrors[name] = error
        return error
    }

    func registrationError(
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationError? {
        registrationErrors[name]
    }

    func handle(id: UInt32) {
        guard let name = idsToNames[id] else {
            return
        }
        actions[name]?()
    }

    private func registerCarbonHotKey(
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationError? {
        unregisterCarbonHotKey(for: name)

        guard let shortcut = shortcut(for: name), actions[name] != nil else {
            return nil
        }

        return registerCarbonHotKey(shortcut, for: name)
    }

    private func registerCarbonHotKey(
        _ shortcut: KeyboardShortcuts.Shortcut,
        for name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationError? {
        guard actions[name] != nil else {
            return nil
        }

        if let error = internalConflictError(for: shortcut, excluding: name) {
            return error
        }

        let id = stableID(for: name)
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.key.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            return KeyboardShortcuts.RegistrationError(
                message: "未更改：快捷键注册失败（\(status)），可能已被系统或其他应用占用。"
            )
        }

        idsToNames[id] = name
        hotKeyRefs[name] = hotKeyRef
        return nil
    }

    private func unregisterCarbonHotKey(for name: KeyboardShortcuts.Name) {
        if let existingRef = hotKeyRefs.removeValue(forKey: name) {
            UnregisterEventHotKey(existingRef)
        }
        idsToNames[stableID(for: name)] = nil
    }

    private func internalConflictError(
        for shortcut: KeyboardShortcuts.Shortcut,
        excluding name: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.RegistrationError? {
        guard hotKeyRefs.keys.contains(where: { registeredName in
            registeredName.rawValue != name.rawValue &&
                self.shortcut(for: registeredName) == shortcut
        }) else {
            return nil
        }

        return KeyboardShortcuts.RegistrationError(
            message: "未更改：该快捷键已被 TTS 的其他功能占用。"
        )
    }

    private func persistShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        for name: KeyboardShortcuts.Name
    ) {
        let key = storageKey(for: name)
        if let shortcut,
           let data = try? JSONEncoder().encode(shortcut) {
            userDefaults.set(data, forKey: key)
            userDefaults.removeObject(forKey: disabledStorageKey(for: name))
        } else {
            userDefaults.removeObject(forKey: key)
            userDefaults.set(true, forKey: disabledStorageKey(for: name))
        }
    }

    private func installHandlerIfNeeded() {
        guard installedHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else {
                return status
            }

            Task { @MainActor in
                HotKeyCenter.shared.handle(id: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &installedHandler
        )
    }

    private func stableID(for name: KeyboardShortcuts.Name) -> UInt32 {
        UInt32(abs(name.rawValue.hashValue) % Int(Int32.max))
    }

    private func storageKey(for name: KeyboardShortcuts.Name) -> String {
        "KeyboardShortcuts.\(name.rawValue)"
    }

    private func disabledStorageKey(for name: KeyboardShortcuts.Name) -> String {
        "\(storageKey(for: name)).disabled"
    }
}

private extension NSEvent.ModifierFlags {
    var normalizedShortcutRawValue: UInt {
        intersection([.command, .option, .control, .shift]).rawValue
    }

    var shortcutDisplay: String {
        var value = ""
        if contains(.control) {
            value += "⌃"
        }
        if contains(.option) {
            value += "⌥"
        }
        if contains(.shift) {
            value += "⇧"
        }
        if contains(.command) {
            value += "⌘"
        }
        return value
    }
}
