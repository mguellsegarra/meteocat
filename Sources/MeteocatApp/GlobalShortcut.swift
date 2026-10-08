import AppKit
import Carbon.HIToolbox
import MeteocatCore

/// One Carbon global hotkey. Registration is exclusive so a conflict is reported instead of silently shared.
@MainActor @Observable
final class GlobalShortcut {
    private(set) var registered: Shortcut?
    /// Persistent problem with the saved shortcut; nil while it works.
    private(set) var errorToken: LocalizedMessage?
    var errorMessage: String? { errorToken?.rendered }
    @ObservationIgnored var onPress: () -> Void = {}
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        installHandler()
        unregister()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: 0x4D54_4354, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            errorToken = status == eventHotKeyExistsErr
                ? .key("La drecera %1$@ ja la fa servir una altra app. Mostra el radar des del Dock o de la barra de menús.", [.shortcut(shortcut)])
                : .key("No s'ha pogut activar la drecera %1$@ (%2$@).", [.shortcut(shortcut), .text(String(status))])
            return false
        }
        hotKey = ref; registered = shortcut; errorToken = nil
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil; registered = nil
    }

    /// Registers `new` first and persists it only if registration worked; otherwise restores `previous`.
    func change(to new: Shortcut, previous: Shortcut?, persist: (Shortcut) async -> LocalizedMessage?) async -> LocalizedMessage? {
        guard register(new) else {
            let message = errorToken
            if let previous { register(previous) }
            return message
        }
        if let failure = await persist(new) {
            if let previous { register(previous) } else { unregister() }
            return failure
        }
        return nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { shortcut.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

enum ShortcutText {
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    static func string(_ shortcut: Shortcut) -> String {
        let m = shortcut.carbonModifiers
        var text = ""
        if m & UInt32(controlKey) != 0 { text += "⌃" }
        if m & UInt32(optionKey) != 0 { text += "⌥" }
        if m & UInt32(shiftKey) != 0 { text += "⇧" }
        if m & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(shortcut.keyCode)
    }

    private static let special: [UInt32: String] = [
        36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Key cap for the current keyboard layout, so the label matches what the user pressed.
    static func keyName(_ code: UInt32) -> String {
        if code == 49 { return L10n.text("Espai") }
        if let name = special[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { buffer in
            UCKeyTranslate(buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
