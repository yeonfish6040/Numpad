import AppKit
import Carbon
import SwiftUI
import TrackpadCore

extension TrackpadCore.KeyboardShortcut {
    var displayName: String {
        guard let keyCode else { return L("Right ⌘ + Right ⌥") }
        let symbols = [(UInt64(0x40000), "⌃"), (0x80000, "⌥"), (0x20000, "⇧"), (0x100000, "⌘")]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = special[code] { return name }
        // Translate in the current input layout rather than assuming a US keyboard.
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                              OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 8, &length, &chars) == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "Key \(code)"
    }
}

struct ShortcutSettings: View {
    @ObservedObject var model: AppController
    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Activation Shortcut")).font(.headline)
            HStack {
                Text(model.shortcutTitle).font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Button(recording ? L("Cancel") : L("Record Shortcut")) {
                    if recording { stop() } else { start() }
                }
                Button(L("Reset")) { stop(); model.activationShortcut = .default }
                    .disabled(model.activationShortcut.isDefault && !recording)
            }
            Text(L(recording ? "Press a key with Command, Option, or Control. Esc cancels." : "Use the shortcut to toggle your selected trackpads. Esc always turns the keypad off."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if invalid {
                Text(L("Include Command, Option, or Control and a non-modifier key. Esc is reserved."))
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }
    private func start() {
        recording = true; invalid = false; model.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let candidate = TrackpadCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue))
            guard candidate.isValid else { invalid = true; return nil }
            model.activationShortcut = candidate
            stop()
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; model.recordingShortcut = false
    }
}

struct KeyArrangementEditor: View {
    @ObservedObject var model: AppController
    @State private var selected: UInt16?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Key Arrangement")).font(.headline)
                Spacer()
                Button(L("Reset Layout")) { selected = nil; model.arrangement = KeyArrangement() }
            }
            Picker(L("Operator Position"), selection: $model.controlSide) {
                Text(L("Left")).tag(KeypadLayout.left)
                Text(L("Right")).tag(KeypadLayout.right)
            }.pickerStyle(.segmented).labelsHidden()
            Text(L("Select two keys to swap them. Slot sizes stay fixed. Each side remembers its own arrangement."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let gap: CGFloat = 6
                let width = (geometry.size.width - gap * 4) / 5
                let height = (geometry.size.height - gap * 3) / 4
                ZStack(alignment: .topLeading) {
                    ForEach(model.keypadKeys) { key in
                        Button {
                            if let first = selected {
                                if first != key.id { model.arrangement.swap(first, key.id) }
                                selected = nil
                            } else { selected = key.id }
                        } label: {
                            Text(key.label).font(.system(size: 20, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .foregroundStyle(selected == key.id ? .black : .white)
                                .background(selected == key.id ? mint : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected == key.id ? mint : .white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(key.label)
                        .accessibilityAddTraits(selected == key.id ? .isSelected : [])
                        .frame(width: width * CGFloat(key.columns) + gap * CGFloat(key.columns - 1),
                               height: height * CGFloat(key.rows) + gap * CGFloat(key.rows - 1))
                        .offset(x: CGFloat(key.column) * (width + gap), y: CGFloat(key.row) * (height + gap))
                    }
                }
            }.frame(height: 235)
        }
        .onChange(of: model.controlSide) { _ in selected = nil }
    }
}
