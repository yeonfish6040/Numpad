import AppKit
import Carbon
import SwiftUI
import TrackpadCore

extension TrackpadCore.KeyboardShortcut {
    var displayName: String {
        guard let keyCode else {
            if isDefault { return L("app.ui.right_command_right_option") }
            let keys: [(UInt64, String)] = [(1, L("app.ui.left_control")), (0x2000, L("app.ui.right_control")),
                (2, L("app.ui.left_shift")), (4, L("app.ui.right_shift")), (8, L("app.ui.left_command")), (16, L("app.ui.right_command")),
                (32, L("app.ui.left_option")), (64, L("app.ui.right_option"))]
            return keys.filter { chordBits & $0.0 != 0 }.map(\.1).joined(separator: " + ")
        }
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
        return String(format: L("app.ui.key_code"), code)
    }
}

/// Monitor lifetime belongs to an object, not a SwiftUI value captured before
/// a redraw. A HID tap captures Command-key equivalents before menus or other
/// apps consume them; a local monitor also supports recording without AX access.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var preview: TrackpadCore.KeyboardShortcut?
    @Published private(set) var problem: String?
    private var state = ShortcutRecording()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    private weak var window: NSWindow?
    private var pending: TrackpadCore.KeyboardShortcut?
    private var completing = false
    private var revision = 0
    var onRecordingChange: ((Bool) -> Void)?
    var onCandidate: ((TrackpadCore.KeyboardShortcut) -> String?)?

    func start() {
        stop()
        window = NSApp.keyWindow
        guard window != nil else { return }
        state = ShortcutRecording(initialFlags: UInt64(NSEvent.modifierFlags.rawValue))
        problem = nil; preview = nil; pending = nil; completing = false
        isRecording = true
        onRecordingChange?(true)
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        if let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async { recorder.stop() }
                    return Unmanaged.passUnretained(event)
                }
                guard NSApp.isActive, recorder.window?.isKeyWindow == true else {
                    DispatchQueue.main.async { recorder.stop() }
                    return Unmanaged.passUnretained(event)
                }
                recorder.receive(type: type, code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                    flags: event.flags.rawValue, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                return type == .flagsChanged ? Unmanaged.passUnretained(event) : nil
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) {
                self.tap = port; self.source = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
            } else {
                CFMachPortInvalidate(port)
            }
        }
        // Keep the local path alongside the HID tap: remote keyboards and
        // assistive input can deliver events above the HID tap. Physical key
        // events consumed by the tap never reach this monitor; duplicate flag
        // changes are harmless and completion is latched.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isRecording, self.window?.isKeyWindow == true else { return event }
            let type: CGEventType = event.type == .flagsChanged ? .flagsChanged : (event.type == .keyDown ? .keyDown : .keyUp)
            self.receive(type: type, code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue),
                         isRepeat: event.type == .keyDown && event.isARepeat)
            return type == .flagsChanged ? event : nil
        }
    }

    private func receive(type: CGEventType, code: UInt16, flags: UInt64, isRepeat: Bool) {
        guard isRecording, !completing else { return }
        if type == .keyUp {
            if let pending, pending.keyCode == code { self.pending = nil; complete(.candidate(pending)) }
            return
        }
        let result = type == .flagsChanged ? state.flagsChanged(flags) : state.keyDown(code: code, flags: flags, isRepeat: isRepeat)
        preview = pending ?? state.preview
        guard let result else { return }
        if case .candidate(let shortcut) = result, !shortcut.isModifierOnly {
            pending = shortcut; preview = shortcut
        } else { complete(result) }
    }

    private func complete(_ result: ShortcutRecording.Result) {
        completing = true
        let session = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, self.revision == session else { return }
            self.completing = false
            switch result {
            case .cancelled: self.stop()
            case .invalid:
                self.problem = L("app.ui.use_two_modifier_keys_or_a_key_with_command_option_or_control_esc_cancels")
                self.state = ShortcutRecording(initialFlags: UInt64(NSEvent.modifierFlags.rawValue))
                self.preview = nil
            case .candidate(let shortcut):
                if let problem = self.onCandidate?(shortcut) {
                    self.problem = problem
                    self.state = ShortcutRecording(initialFlags: UInt64(NSEvent.modifierFlags.rawValue))
                    self.preview = nil
                }
                else { self.stop() }
            }
        }
    }

    func stop() {
        revision += 1
        problem = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        tap = nil; source = nil; monitor = nil; window = nil
        pending = nil; preview = nil; completing = false
        if isRecording { isRecording = false; onRecordingChange?(false) }
    }
    deinit { stop() }
}

struct ShortcutSettings: View {
    @ObservedObject var model: AppController
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("app.ui.activation_shortcut")).font(.headline)
            HStack {
                Text(recorder.preview?.displayName ?? model.shortcutTitle).font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Button(recorder.isRecording ? L("app.ui.cancel") : L("app.ui.record_shortcut")) {
                    if recorder.isRecording { recorder.stop() }
                    else {
                        recorder.onRecordingChange = { [weak target = model] in target?.recordingShortcut = $0 }
                        recorder.onCandidate = { [weak target = model] in target?.setActivationShortcut($0) }
                        recorder.start()
                    }
                }
                Button(L("app.ui.reset")) { recorder.stop(); model.activationShortcut = .default }
                    .disabled(model.activationShortcut.isDefault && !recorder.isRecording)
            }
            Text(L(recorder.isRecording ? "app.ui.press_and_release_your_shortcut_use_two_modifier_keys_or_a_key_with_command_option_or_control_esc_cancels" : "app.ui.use_the_shortcut_to_toggle_your_selected_trackpads_esc_always_turns_the_keypad_off"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let problem = recorder.problem ?? model.shortcutProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text(L("app.ui.macos_shortcuts_and_registered_global_shortcuts_are_checked_some_app_specific_shortcuts_and_modifier_only_shortcuts_cannot_be_checked"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            // Ignore notifications from unrelated panels and applications.
            if let window = notification.object as? NSWindow, window.title == L("app.ui.numpad_settings") { recorder.stop() }
        }
    }
}

struct KeyArrangementEditor: View {
    @ObservedObject var model: AppController
    @State private var selected: UInt16?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("app.ui.key_arrangement")).font(.headline)
                Spacer()
                Button(L("app.ui.reset_layout")) { selected = nil; model.arrangement = KeyArrangement() }
            }
            Picker(L("app.ui.operator_position"), selection: $model.controlSide) {
                Text(L("app.ui.left")).tag(KeypadLayout.left)
                Text(L("app.ui.right")).tag(KeypadLayout.right)
            }.pickerStyle(.segmented).labelsHidden()
            Text(L("app.ui.select_two_keys_to_swap_them_slot_sizes_stay_fixed_each_side_remembers_its_own_arrangement"))
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
