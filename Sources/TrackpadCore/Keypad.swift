import Foundation

public struct PadKey: Equatable, Identifiable, Sendable {
    public let label: String
    public let keyCode: UInt16
    public let column: Int
    public let row: Int
    public var columns: Int = 1
    public var rows: Int = 1
    public var id: UInt16 { keyCode }
    public var isOperation: Bool { [51, 75, 67, 78, 69, 76].contains(keyCode) }

    public static let columnCount = 5
    public static let rowCount = 4
    public static let all: [PadKey] = [
        .init(label: "7", keyCode: 89, column: 0, row: 0),
        .init(label: "8", keyCode: 91, column: 1, row: 0),
        .init(label: "9", keyCode: 92, column: 2, row: 0),
        .init(label: "4", keyCode: 86, column: 0, row: 1),
        .init(label: "5", keyCode: 87, column: 1, row: 1),
        .init(label: "6", keyCode: 88, column: 2, row: 1),
        .init(label: "1", keyCode: 83, column: 0, row: 2),
        .init(label: "2", keyCode: 84, column: 1, row: 2),
        .init(label: "3", keyCode: 85, column: 2, row: 2),
        .init(label: "0", keyCode: 82, column: 0, row: 3, columns: 2),
        .init(label: ".", keyCode: 65, column: 2, row: 3),
        .init(label: "⌫", keyCode: 51, column: 3, row: 0),
        .init(label: "÷", keyCode: 75, column: 4, row: 0),
        .init(label: "×", keyCode: 67, column: 3, row: 1),
        .init(label: "−", keyCode: 78, column: 4, row: 1),
        .init(label: "+", keyCode: 69, column: 3, row: 2, rows: 2),
        .init(label: "↵", keyCode: 76, column: 4, row: 2, rows: 2)
    ]

    // Hardware coordinates have their origin at the bottom left.
    public static func at(x: Double, y: Double, layout: KeypadLayout = .right, keys: [PadKey]? = nil) -> PadKey? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        let column = min(columnCount - 1, Int(x * Double(columnCount)))
        let row = min(rowCount - 1, Int((1 - y) * Double(rowCount)))
        return (keys ?? layout.keys).first { column >= $0.column && column < $0.column + $0.columns &&
            row >= $0.row && row < $0.row + $0.rows }
    }
}

public enum KeypadLayout: String, CaseIterable, Sendable {
    case left, right
    private static let leftKeys = PadKey.all.map {
        PadKey(label: $0.label, keyCode: $0.keyCode, column: $0.column + ($0.isOperation ? -3 : 2),
               row: $0.row, columns: $0.columns, rows: $0.rows)
    }
    public var keys: [PadKey] { self == .left ? Self.leftKeys : PadKey.all }
    public func center(of label: String) -> PadPoint {
        let key = keys.first { $0.label == label }!
        return PadPoint(x: (Double(key.column) + Double(key.columns) / 2) / Double(PadKey.columnCount),
                        y: 1 - (Double(key.row) + Double(key.rows) / 2) / Double(PadKey.rowCount))
    }
}

public struct Touch: Sendable {
    public let id: Int32
    public let x: Double
    public let y: Double
    public init(id: Int32, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// Emits once at lift-off. A swipe, long press, or extra finger cancels the entire gesture.
public struct TapRecognizer {
    public private(set) var beganKey: PadKey?
    private var start: Touch?
    private var key: PadKey?
    private var beganAt: Double = 0
    private var cancelled = false
    public var maximumDuration: Double = 0.45
    public var maximumTravel: Double = 0.055
    public var layout: KeypadLayout
    public var keys: [PadKey]?
    public init(layout: KeypadLayout = .right, keys: [PadKey]? = nil) { self.layout = layout; self.keys = keys }

    public mutating func reset(waitForLift: Bool = false) {
        start = nil; key = nil; beganKey = nil; cancelled = waitForLift
    }

    public mutating func process(_ touches: [Touch], at timestamp: Double) -> PadKey? {
        beganKey = nil
        guard timestamp.isFinite else { reset(waitForLift: true); return nil }
        if touches.isEmpty {
            defer { reset() }
            let duration = timestamp - beganAt
            guard start != nil, !cancelled, duration >= 0.025, duration <= maximumDuration else { return nil }
            return key
        }
        guard touches.count == 1, !cancelled else { cancelled = true; return nil }
        let touch = touches[0]
        guard let currentKey = PadKey.at(x: touch.x, y: touch.y, layout: layout, keys: keys) else { cancelled = true; return nil }
        if let first = start {
            let distance = hypot(touch.x - first.x, touch.y - first.y)
            if touch.id != first.id || currentKey != key || distance > maximumTravel ||
                timestamp < beganAt || timestamp - beganAt > maximumDuration { cancelled = true }
        } else {
            start = touch; key = currentKey; beganAt = timestamp
            beganKey = currentKey
        }
        return nil
    }
}
