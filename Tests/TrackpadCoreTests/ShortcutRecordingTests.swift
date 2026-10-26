import XCTest
@testable import TrackpadCore

final class ShortcutRecordingTests: XCTestCase {
    func testDefaultModifierChordRecordsOnReleaseWithoutNormalKey() {
        var recorder = ShortcutRecording()
        XCTAssertNil(recorder.flagsChanged(0x100010))
        XCTAssertNil(recorder.flagsChanged(0x180050))
        XCTAssertNil(recorder.flagsChanged(0x100010))
        guard case .candidate(let result) = recorder.flagsChanged(0) else { return XCTFail("Chord was not recorded") }
        XCTAssertTrue(result.isDefault)
        XCTAssertTrue(result.isValid)
    }

    func testThreeModifierChordDoesNotCommitFirstTwoAndMatchesSidesExactly() {
        var recorder = ShortcutRecording()
        _ = recorder.flagsChanged(0x100008)
        _ = recorder.flagsChanged(0x180028)
        _ = recorder.flagsChanged(0x1A002A)
        _ = recorder.flagsChanged(0x180028)
        guard case .candidate(let shortcut) = recorder.flagsChanged(0) else { return XCTFail() }
        XCTAssertEqual(shortcut.chordBits, 0x2A)
        XCTAssertFalse(shortcut.isDefault)
        var matcher = ModifierShortcutMatcher()
        XCTAssertTrue(matcher.update(flags: 0x1A002A, shortcut: shortcut))
        XCTAssertFalse(matcher.update(flags: 0x1A002A, shortcut: shortcut))
        XCTAssertFalse(matcher.update(flags: 0x1A0054, shortcut: shortcut))
        XCTAssertFalse(matcher.update(flags: 0x1E202B, shortcut: shortcut))
        XCTAssertTrue(matcher.update(flags: 0x1A002A, shortcut: shortcut))
    }

    func testCommandKeyEquivalentAndEscapeAreRecordedWithoutModifierOnlyDuplicate() {
        var recorder = ShortcutRecording()
        _ = recorder.flagsChanged(0x180050)
        let candidate = KeyboardShortcut(keyCode: 40, modifiers: 0x180000)
        XCTAssertEqual(recorder.keyDown(code: 40, flags: 0x180050), .candidate(candidate))
        XCTAssertNil(recorder.flagsChanged(0))
        XCTAssertEqual(recorder.keyDown(code: 53, flags: 0), .cancelled)
    }

    func testInvalidBareKeyRepeatAndHeldModifiersAtStartDoNotSave() {
        var recorder = ShortcutRecording(initialFlags: 0x180050)
        XCTAssertNil(recorder.keyDown(code: 40, flags: 0x180050))
        XCTAssertNil(recorder.flagsChanged(0))
        XCTAssertEqual(recorder.keyDown(code: 40, flags: 0), .invalid)
        XCTAssertNil(recorder.keyDown(code: 40, flags: 0x100000, isRepeat: true))
        _ = recorder.flagsChanged(0)
        XCTAssertEqual(recorder.keyDown(code: 40, flags: 0x100000),
                       .candidate(KeyboardShortcut(keyCode: 40, modifiers: 0x100000)))
    }

    func testOldStoredShortcutRemainsCompatibleAndNewModifierChordPersists() throws {
        let suite = "Numpad.ShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"modifiers":0}"#.utf8), forKey: "activationShortcut")
        XCTAssertTrue(KeyboardShortcut.load(from: defaults).isDefault)
        let shortcut = KeyboardShortcut(keyCode: nil, modifiers: 0, sideModifiers: 0x28)
        defaults.set(try JSONEncoder().encode(shortcut), forKey: "activationShortcut")
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), shortcut)
        XCTAssertFalse(KeyboardShortcut(keyCode: nil, modifiers: 0, sideModifiers: 0x10).isValid)
    }
}
