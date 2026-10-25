import Foundation
import XCTest
@testable import TrackpadCore

final class InputConfigurationTests: XCTestCase {
    func testSwappingSpanningKeyChangesHitTestingAndTapOutputOnBothSides() throws {
        var arrangement = KeyArrangement()
        arrangement.swap(82, 87) // wide 0 slot now types 5
        for layout in KeypadLayout.allCases {
            let keys = arrangement.keys(for: layout)
            let five = try XCTUnwrap(keys.first { $0.label == "5" })
            XCTAssertEqual(five.columns, 2)
            for offset in [0.25, 1.75] {
                let x = (Double(five.column) + offset) / 5
                let y = 1 - (Double(five.row) + 0.5) / 4
                XCTAssertEqual(PadKey.at(x: x, y: y, layout: layout, keys: keys)?.label, "5")
                var recognizer = AnchoredTapRecognizer(layout: layout, keys: keys)
                _ = recognizer.process([Touch(id: 1, x: x, y: y)], at: 1)
                XCTAssertEqual(recognizer.process([], at: 1.08)?.keyCode, 87)
            }
            XCTAssertEqual(Set(keys.map(\.keyCode)), Set(PadKey.all.map(\.keyCode)))
        }
    }

    func testCenterFeedbackFollowsMovedFive() throws {
        var arrangement = KeyArrangement()
        arrangement.swap(87, 89)
        let keys = arrangement.keys(for: .right)
        var center = CenterCrossingFeedback(layout: .right, keys: keys)
        _ = center.processEvents([Touch(id: 1, x: 0.12, y: 0.875)])
        XCTAssertTrue(center.processEvents([Touch(id: 1, x: 0.1, y: 0.875)]).contains(.entered))
        center.reset()
        _ = center.processEvents([Touch(id: 1, x: 0.32, y: 0.625)])
        XCTAssertTrue(center.processEvents([Touch(id: 1, x: 0.3, y: 0.625)]).isEmpty)
    }

    func testArrangementPersistenceIsSeparateBySideAndCorruptionFallsBack() throws {
        let suite = "Numpad.InputTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var arrangement = KeyArrangement()
        arrangement.swap(83, 89)
        arrangement.save(to: defaults, layout: .left)
        XCTAssertEqual(KeyArrangement.load(from: defaults, layout: .left), arrangement)
        XCTAssertEqual(KeyArrangement.load(from: defaults, layout: .right), KeyArrangement())
        defaults.set(Data(#"{"codes":[87,87]}"#.utf8), forKey: "keyArrangement.left")
        XCTAssertEqual(KeyArrangement.load(from: defaults, layout: .left), KeyArrangement())
    }

    func testCustomShortcutRejectsRepeatExtraModifiersEscapeAndBareKeys() {
        let shortcut = KeyboardShortcut(keyCode: 40, modifiers: 0x180000) // Option-Command-K
        XCTAssertTrue(shortcut.isValid)
        XCTAssertTrue(shortcut.matches(keyCode: 40, flags: 0x180050, isRepeat: false))
        XCTAssertFalse(shortcut.matches(keyCode: 40, flags: 0x180050, isRepeat: true))
        XCTAssertFalse(shortcut.matches(keyCode: 40, flags: 0x1A0000, isRepeat: false))
        XCTAssertFalse(shortcut.matches(keyCode: 41, flags: 0x180000, isRepeat: false))
        XCTAssertFalse(KeyboardShortcut(keyCode: 53, modifiers: 0x100000).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 40, modifiers: 0).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 40, modifiers: 0x20000).isValid)
        XCTAssertTrue(KeyboardShortcut.default.isValid)
    }

    func testUnselectedAndUnknownDevicesPassDuringSelectedTrackpadCalibration() {
        var filter = DevicePointerFilter(selected: [100])
        filter.updateTouches(deviceID: 100, count: 3, calibrationEnabled: true)
        for kind: PointerEventKind in [.move, .scroll, .gesture, .down(0), .drag(0), .up(0)] {
            XCTAssertFalse(filter.allows(kind, deviceID: 100))
            XCTAssertTrue(filter.allows(kind, deviceID: 200))
            XCTAssertTrue(filter.allows(kind, deviceID: 0))
        }
    }

    func testClickPairingAndCalibrationLatchAreIndependentAcrossDevices() {
        var filter = DevicePointerFilter(selected: [100, 200])
        XCTAssertFalse(filter.allows(.down(0), deviceID: 100)) // tap-to-click
        XCTAssertTrue(filter.allows(.down(0), deviceID: 200, pressure: 1))
        XCTAssertFalse(filter.allows(.up(0), deviceID: 100))
        XCTAssertTrue(filter.allows(.drag(0), deviceID: 200))
        XCTAssertTrue(filter.allows(.up(0), deviceID: 200))
        filter.updateTouches(deviceID: 100, count: 3, calibrationEnabled: true)
        filter.updateTouches(deviceID: 100, count: 2, calibrationEnabled: true)
        XCTAssertFalse(filter.allows(.down(0), deviceID: 100, pressure: 1))
        XCTAssertTrue(filter.allows(.down(0), deviceID: 200, pressure: 1))
        filter.updateTouches(deviceID: 100, count: 0, calibrationEnabled: true)
        XCTAssertTrue(filter.allows(.down(0), deviceID: 100, pressure: 1))
    }

    func testCalibrationUsesTheRearrangedKeyCenters() throws {
        var arrangement = KeyArrangement()
        arrangement.swap(87, 91) // move 5 one row up; 4 and 6 stay where they are
        let keys = arrangement.keys(for: .right)
        let transform = try PadTransform.calibrating([
            PadPoint(x: 0.1, y: 0.625), PadPoint(x: 0.3, y: 0.875), PadPoint(x: 0.5, y: 0.625)
        ], layout: .right, keys: keys, preserveOrder: true)
        XCTAssertEqual(transform.a, 1, accuracy: 1e-8)
        XCTAssertEqual(transform.tx, 0, accuracy: 1e-8)
        XCTAssertEqual(transform.ty, 0, accuracy: 1e-8)
    }
}
