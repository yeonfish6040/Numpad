import Foundation

public enum PadGeometry {
    public static let aspectRatio = 1.7
}

public enum CalibrationTiming: String, CaseIterable, Sendable {
    case touchDown, liftOff
}

public struct PadPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum CalibrationError: Error, LocalizedError {
    case invalidPoints, tooClose
    public var errorDescription: String? {
        switch self {
        case .invalidPoints: return "Try tapping again within the trackpad."
        case .tooClose: return "Move your fingers a little farther apart."
        }
    }
}

/// Raw trackpad coordinates -> logical keypad coordinates, both bottom-left origin.
public struct PadTransform: Codable, Equatable, Sendable {
    public let a, b, c, d, tx, ty: Double
    public static let identity = PadTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public var isUsable: Bool {
        [a, b, c, d, tx, ty].allSatisfy { $0.isFinite && abs($0) < 1_000 } && abs(a * d - b * c) > 1e-8
    }
    public func apply(_ p: PadPoint) -> PadPoint {
        PadPoint(x: a * p.x + b * p.y + tx, y: c * p.x + d * p.y + ty)
    }
    public func apply(_ touch: Touch) -> Touch {
        let p = apply(PadPoint(x: touch.x, y: touch.y))
        return Touch(id: touch.id, x: p.x, y: p.y)
    }
    public var inverse: PadTransform {
        let determinant = a * d - b * c
        guard isUsable else { return .identity }
        return PadTransform(a: d / determinant, b: -b / determinant, c: -c / determinant, d: a / determinant,
                            tx: (b * ty - d * tx) / determinant, ty: (c * tx - a * ty) / determinant)
    }

    public static func rigid(source: [PadPoint], target: [PadPoint]) throws -> PadTransform {
        try fit(source: source, target: target, allowScale: false)
    }

    /// Least-squares translation, rotation and uniform scale. No shear/reflection.
    public static func similarity(source: [PadPoint], target: [PadPoint]) throws -> PadTransform {
        try fit(source: source, target: target, allowScale: true)
    }

    private static func fit(source: [PadPoint], target: [PadPoint], allowScale: Bool) throws -> PadTransform {
        guard source.count >= 2, source.count == target.count,
              (source + target).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw CalibrationError.invalidPoints
        }
        let aspect = PadGeometry.aspectRatio
        for i in source.indices {
            for j in source.indices where j > i {
                guard hypot((source[i].x - source[j].x) * aspect, source[i].y - source[j].y) >= 0.025 else {
                    throw CalibrationError.tooClose
                }
            }
        }
        let count = Double(source.count)
        let sx = source.map(\.x).reduce(0, +) / count
        let sy = source.map(\.y).reduce(0, +) / count
        let tx = target.map(\.x).reduce(0, +) / count
        let ty = target.map(\.y).reduce(0, +) / count
        var dot = 0.0, cross = 0.0, variance = 0.0
        for (p, q) in zip(source, target) {
            let x = (p.x - sx) * aspect, y = p.y - sy
            let u = (q.x - tx) * aspect, v = q.y - ty
            variance += x * x + y * y
            dot += x * u + y * v
            cross += x * v - y * u
        }
        guard hypot(dot, cross) > 1e-10 else { throw CalibrationError.invalidPoints }
        let angle = atan2(cross, dot)
        let scale = allowScale ? hypot(dot, cross) / variance : 1
        let a = scale * cos(angle), b = -scale * sin(angle) / aspect
        let c = scale * sin(angle) * aspect, d = scale * cos(angle)
        return PadTransform(a: a, b: b, c: c, d: d,
                            tx: tx - a * sx - b * sy, ty: ty - c * sx - d * sy)
    }

    public var isSimilarity: Bool {
        let aspect = PadGeometry.aspectRatio
        return isUsable && abs(a - d) < 1e-8 && abs(b * aspect + c / aspect) < 1e-8 && a * d - b * c > 0
    }

    public var isRigid: Bool {
        let aspect = PadGeometry.aspectRatio
        return isUsable && abs(a - d) < 1e-8 && abs(b * aspect + c / aspect) < 1e-8 &&
            abs(a * a + (c / aspect) * (c / aspect) - 1) < 1e-8 && abs(a * d - b * c - 1) < 1e-8
    }

    public static func calibrating(_ points: [PadPoint], layout: KeypadLayout, keys: [PadKey]? = nil, preserveOrder: Bool = false, reference: PadTransform = .identity) throws -> PadTransform {
        guard points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw CalibrationError.invalidPoints
        }
        func center(_ label: String) -> PadPoint {
            guard let key = keys?.first(where: { $0.label == label }) else { return layout.center(of: label) }
            return PadPoint(x: (Double(key.column) + Double(key.columns) / 2) / Double(PadKey.columnCount),
                            y: 1 - (Double(key.row) + Double(key.rows) / 2) / Double(PadKey.rowCount))
        }
        let sorted = preserveOrder ? points : FingerOrdering.ordered(points, reference: reference)
        for i in sorted.indices {
            for j in sorted.indices where j > i {
                guard hypot((sorted[i].x - sorted[j].x) * PadGeometry.aspectRatio, sorted[i].y - sorted[j].y) >= 0.025 else {
                    throw CalibrationError.tooClose
                }
            }
        }
        let placement: PadTransform
        switch sorted.count {
        case 3:
            // Outer fingers determine only rotation and uniform scale. The
            // middle contact is the translation anchor, exactly at key 5.
            let outer = try similarity(source: ["4", "6"].map { center($0) },
                                       target: [sorted[0], sorted[2]])
            let center = center("5")
            placement = PadTransform(a: outer.a, b: outer.b, c: outer.c, d: outer.d,
                tx: sorted[1].x - outer.a * center.x - outer.b * center.y,
                ty: sorted[1].y - outer.c * center.x - outer.d * center.y)
        case 4:
            placement = try similarity(source: ["×", "−"].map { center($0) }, target: Array(sorted[1...2]))
        default: throw CalibrationError.invalidPoints
        }
        // Fit displayed key centers to physical fingers, then invert for input.
        // Three-finger placement keeps 5 pinned even with uneven finger spacing.
        let transform = placement.inverse
        guard transform.isSimilarity else { throw CalibrationError.invalidPoints }
        return transform
    }
}

public struct CalibrationFrame {
    public let consumed: Bool
    public let points: [PadPoint]?
}

/// Capture a simultaneous three/four-finger tap, committing only after all lift.
/// The whole multi-contact sequence is consumed so calibration cannot type keys.
public struct CalibrationGesture {
    private var beganAt: Double?
    private var origins: [Int32: PadPoint] = [:]
    private var snapshot: [Touch] = []
    private var consumed = false
    private var invalid = false
    private var blocked = false
    public init() {}
    public mutating func reset(waitForLift: Bool = false) {
        beganAt = nil; origins = [:]; snapshot = []; consumed = false; invalid = false; blocked = waitForLift
    }
    public mutating func process(_ touches: [Touch], at timestamp: Double, allowFour: Bool) -> CalibrationFrame {
        if blocked {
            if touches.isEmpty { reset() }
            return CalibrationFrame(consumed: true, points: nil)
        }
        guard timestamp.isFinite else { reset(waitForLift: true); return CalibrationFrame(consumed: true, points: nil) }
        if touches.isEmpty {
            let duration = timestamp - (beganAt ?? timestamp)
            let result = !invalid && consumed && duration >= 0.025 && duration <= 0.45 &&
                (snapshot.count == 3 || (allowFour && snapshot.count == 4))
            let frame = CalibrationFrame(consumed: consumed, points: result ? snapshot.map { PadPoint(x: $0.x, y: $0.y) } : nil)
            reset(); return frame
        }
        if beganAt == nil { beganAt = timestamp }
        let elapsed = timestamp - beganAt!
        if elapsed < 0 { invalid = true }
        for touch in touches {
            guard touch.x.isFinite, touch.y.isFinite else { invalid = true; continue }
            if let origin = origins[touch.id] {
                if hypot(touch.x - origin.x, touch.y - origin.y) > 0.035 { invalid = true }
            } else {
                if elapsed > 0.12 { invalid = true }
                origins[touch.id] = PadPoint(x: touch.x, y: touch.y)
            }
        }
        if touches.count >= 3 { consumed = true }
        if origins.count > (allowFour ? 4 : 3) { invalid = true }
        if touches.count > snapshot.count { snapshot = touches }
        return CalibrationFrame(consumed: consumed, points: nil)
    }
}
