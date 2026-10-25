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
    public static let modifierMask: UInt64 = 0x1E0000 // shift/control/option/command
    public static let `default` = Self(keyCode: nil, modifiers: 0)
    public init(keyCode: UInt16?, modifiers: UInt64) {
        self.keyCode = keyCode; self.modifiers = modifiers & Self.modifierMask
    }
    public var isDefault: Bool { keyCode == nil }
    public var isValid: Bool {
        isDefault || (keyCode! <= 127 && keyCode != 53 && modifiers & 0x1C0000 != 0 &&
            ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode!))
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "activationShortcut"),
              let shortcut = try? JSONDecoder().decode(Self.self, from: data), shortcut.isValid else { return .default }
        return Self(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }
    public func matches(keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
        !isDefault && !isRepeat && self.keyCode == keyCode && flags & Self.modifierMask == modifiers
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
