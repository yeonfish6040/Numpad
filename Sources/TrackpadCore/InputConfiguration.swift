import Foundation

/// A permutation of the existing keys. Slot geometry stays intact, including
/// the wide zero and tall Enter/+ slots; every output remains reachable.
public struct KeyArrangement: Codable, Equatable, Sendable {
    public private(set) var codes: [UInt16]
    public init(codes: [UInt16] = PadKey.all.map(\.keyCode)) {
        self.codes = codes.count == PadKey.all.count && Set(codes) == Set(PadKey.all.map(\.keyCode))
            ? codes : PadKey.all.map(\.keyCode)
    }
    public func keys(for layout: KeypadLayout) -> [PadKey] {
        let valid = KeyArrangement(codes: codes).codes
        return zip(layout.keys, valid).map { slot, code in
            let output = PadKey.all.first { $0.keyCode == code }!
            return PadKey(label: output.label, keyCode: code, column: slot.column, row: slot.row,
                          columns: slot.columns, rows: slot.rows)
        }
    }
    public mutating func swap(_ first: UInt16, _ second: UInt16) {
        guard let a = codes.firstIndex(of: first), let b = codes.firstIndex(of: second) else { return }
        codes.swapAt(a, b)
    }
    public static func load(from defaults: UserDefaults = .standard, layout: KeypadLayout) -> Self {
        guard let data = defaults.data(forKey: "keyArrangement." + layout.rawValue),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return Self(codes: saved.codes)
    }
    public func save(to defaults: UserDefaults = .standard, layout: KeypadLayout) {
        defaults.set(try? JSONEncoder().encode(self), forKey: "keyArrangement." + layout.rawValue)
    }
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16?
    public var modifiers: UInt64
    // Optional for compatibility with shortcuts saved before modifier-only recording.
    public var sideModifiers: UInt64?
    public static let modifierMask: UInt64 = 0x1E0000
    public static let sideMask: UInt64 = 0x207F
    public static let `default` = Self(keyCode: nil, modifiers: 0)
    public init(keyCode: UInt16?, modifiers: UInt64, sideModifiers: UInt64? = nil) {
        self.keyCode = keyCode; self.modifiers = modifiers & Self.modifierMask
        self.sideModifiers = sideModifiers.map { $0 & Self.sideMask }
    }
    public var isModifierOnly: Bool { keyCode == nil }
    public var chordBits: UInt64 { sideModifiers ?? 0x50 }
    public var isDefault: Bool { isModifierOnly && chordBits == 0x50 }
    public var isValid: Bool {
        if isModifierOnly { return chordBits.nonzeroBitCount >= 2 }
        return keyCode! <= 127 && keyCode != 53 && modifiers & 0x1C0000 != 0 &&
            ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode!)
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "activationShortcut"),
              let shortcut = try? JSONDecoder().decode(Self.self, from: data), shortcut.isValid else { return .default }
        return Self(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, sideModifiers: shortcut.sideModifiers)
    }
    public func matches(keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
        !isModifierOnly && !isRepeat && self.keyCode == keyCode && flags & Self.modifierMask == modifiers
    }
    public func matchesModifiers(flags: UInt64) -> Bool {
        guard isModifierOnly, flags & Self.sideMask == chordBits else { return false }
        // Some keyboards omit side bits for extra modifiers. Reject these too.
        var expected: UInt64 = 0
        if chordBits & 0x18 != 0 { expected |= 0x100000 }
        if chordBits & 0x60 != 0 { expected |= 0x80000 }
        if chordBits & 0x06 != 0 { expected |= 0x20000 }
        if chordBits & 0x2001 != 0 { expected |= 0x40000 }
        return flags & Self.modifierMask == expected
    }
}

public struct ModifierShortcutMatcher {
    private var held = false
    public init() {}
    public mutating func reset() { held = false }
    public mutating func update(flags: UInt64, shortcut: KeyboardShortcut) -> Bool {
        let matches = shortcut.matchesModifiers(flags: flags)
        defer { held = matches }
        return matches && !held
    }
}

/// Completes a modifier-only chord only after every modifier lifts, allowing
/// three/four-key chords to be recorded without committing the first two keys.
public struct ShortcutRecording {
    public enum Result: Equatable { case candidate(KeyboardShortcut), invalid, cancelled }
    public private(set) var preview: KeyboardShortcut?
    private var peak: UInt64 = 0
    private var keyPressed = false
    private var waitingForRelease = false
    public init(initialFlags: UInt64 = 0) { waitingForRelease = initialFlags & KeyboardShortcut.sideMask != 0 }
    public mutating func flagsChanged(_ flags: UInt64) -> Result? {
        let bits = flags & KeyboardShortcut.sideMask
        if waitingForRelease {
            if bits == 0 { waitingForRelease = false }
            return nil
        }
        if bits.nonzeroBitCount > peak.nonzeroBitCount {
            peak = bits
            preview = KeyboardShortcut(keyCode: nil, modifiers: flags, sideModifiers: bits)
        }
        guard bits == 0 else { return nil }
        defer { peak = 0; keyPressed = false; preview = nil }
        guard !keyPressed, peak.nonzeroBitCount >= 2 else { return nil }
        return .candidate(KeyboardShortcut(keyCode: nil, modifiers: 0, sideModifiers: peak))
    }
    public mutating func keyDown(code: UInt16, flags: UInt64, isRepeat: Bool = false) -> Result? {
        if code == 53 { return .cancelled }
        guard !waitingForRelease, !isRepeat else { return nil }
        keyPressed = true
        let shortcut = KeyboardShortcut(keyCode: code, modifiers: flags)
        return shortcut.isValid ? .candidate(shortcut) : .invalid
    }
}

/// Attribution is deliberately fail-open: an unknown sender never suppresses
/// another pointing device, even while a selected trackpad is being touched.
public struct DeviceInputPolicy {
    public var selected: Set<UInt64>
    public init(selected: Set<UInt64> = []) { self.selected = selected }
    public func shouldFilter(deviceID: UInt64) -> Bool { deviceID != 0 && selected.contains(deviceID) }
}

public enum PointerEventKind {
    case move, scroll, gesture, down(Int), up(Int), drag(Int)
}

/// Decisions and button pairing belong to a device, never to the global
/// pointer. Two devices may hold the same button at the same time.
public struct DevicePointerFilter {
    public var policy: DeviceInputPolicy
    private var clicks: [UInt64: ClickFilter] = [:]
    private var calibration: [UInt64: ThreeFingerDragSuppression] = [:]
    public init(selected: Set<UInt64> = []) { policy = DeviceInputPolicy(selected: selected) }
    public mutating func updateTouches(deviceID: UInt64, count: Int, calibrationEnabled: Bool) {
        guard policy.shouldFilter(deviceID: deviceID) else { return }
        calibration[deviceID, default: ThreeFingerDragSuppression()].update(contactCount: count, enabled: calibrationEnabled)
    }
    public mutating func allows(_ kind: PointerEventKind, deviceID: UInt64, pressure: Double = 0) -> Bool {
        guard policy.shouldFilter(deviceID: deviceID) else { return true }
        switch kind {
        case .move, .scroll, .gesture: return false
        case .down(let button):
            return clicks[deviceID, default: ClickFilter()].down(button: button, pressure: pressure,
                recentTrackpadTouch: true, forceSuppress: calibration[deviceID]?.active == true)
        case .up(let button): return clicks[deviceID, default: ClickFilter()].up(button: button)
        case .drag(let button):
            return calibration[deviceID]?.active != true && clicks[deviceID, default: ClickFilter()].drag(button: button)
        }
    }
}
