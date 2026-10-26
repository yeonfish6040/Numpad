import AppKit
import Carbon
import TrackpadCore

enum ShortcutAvailability {
    static func carbonModifiers(_ shortcut: TrackpadCore.KeyboardShortcut) -> UInt32 {
        var flags: UInt32 = 0
        for (mask, carbon): (UInt64, Int) in [(0x100000, cmdKey), (0x80000, optionKey), (0x40000, controlKey), (0x20000, shiftKey)] {
            if shortcut.modifiers & mask != 0 { flags |= UInt32(carbon) }
        }
        return flags
    }

    static func systemConflict(_ shortcut: TrackpadCore.KeyboardShortcut) -> Bool {
        guard let code = shortcut.keyCode else { return false }
        var entries: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&entries) == noErr,
              let keys = entries?.takeRetainedValue() as? [[String: Any]] else { return false }
        return keys.contains {
            ($0[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true &&
            ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value == code &&
            ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == carbonModifiers(shortcut)
        }
    }

    /// Exclusive registration fails if another app already registered this
    /// combination, including a non-exclusive registration. Never displace it.
    static func registrationError(_ shortcut: TrackpadCore.KeyboardShortcut) -> OSStatus {
        guard let code = shortcut.keyCode else { return noErr }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), carbonModifiers(shortcut),
            EventHotKeyID(signature: 0x4E506164, id: 2), GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status
    }

    static func problem(_ shortcut: TrackpadCore.KeyboardShortcut) -> String? {
        guard shortcut.isValid else { return L("Use two modifier keys, or a key with Command, Option, or Control. Esc cancels.") }
        if systemConflict(shortcut) { return L("This shortcut is assigned in macOS Keyboard Shortcuts. Choose another combination.") }
        let status = registrationError(shortcut)
        if status != noErr { return L("This shortcut is unavailable or registered by another app. Choose another combination.") + " (\(status))" }
        return nil
    }
}
