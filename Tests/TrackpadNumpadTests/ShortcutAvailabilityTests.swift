import Carbon
import TrackpadCore
import XCTest
@testable import TrackpadNumpad

final class ShortcutAvailabilityTests: XCTestCase {
    func testAnotherAppsNonExclusiveHotKeyIsRejectedWithoutDisplacingIt() throws {
        // A temporary F20 + all modifiers reservation simulates another app.
        let shortcut = TrackpadCore.KeyboardShortcut(keyCode: 90, modifiers: 0x1E0000)
        var existing: EventHotKeyRef?
        let status = RegisterEventHotKey(90, ShortcutAvailability.carbonModifiers(shortcut),
            EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), 0, &existing)
        guard status == noErr, let existing else { throw XCTSkip("Test hotkey unavailable: \(status)") }
        defer { UnregisterEventHotKey(existing) }
        XCTAssertNotEqual(ShortcutAvailability.registrationError(shortcut), noErr)
        XCTAssertNotNil(ShortcutAvailability.problem(shortcut))
    }

    func testEnabledSystemShortcutIsDetected() throws {
        var entries: Unmanaged<CFArray>?
        XCTAssertEqual(CopySymbolicHotKeys(&entries), noErr)
        let items = try XCTUnwrap(entries?.takeRetainedValue() as? [[String: Any]])
        guard let item = items.first(where: { ($0[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true }),
              let code = item[kHISymbolicHotKeyCode as String] as? NSNumber,
              let flags = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { throw XCTSkip("No enabled system shortcut") }
        var modifiers: UInt64 = 0
        for (mask, flag): (Int, UInt64) in [(cmdKey, 0x100000), (optionKey, 0x80000), (controlKey, 0x40000), (shiftKey, 0x20000)] {
            if flags.intValue & mask != 0 { modifiers |= flag }
        }
        XCTAssertTrue(ShortcutAvailability.systemConflict(.init(keyCode: code.uint16Value, modifiers: modifiers)))
    }
}
