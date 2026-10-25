import Foundation
import Darwin

/// Recover zoom preferences left in an older release's crash journal.
/// New sessions never alter these global settings.
final class ScreenZoomSuppression {
    private typealias Read = @convention(c) () -> Bool
    private typealias Write = @convention(c) (Bool) -> Void
    private struct Setting {
        let name: String
        let read: Read
        let write: Write
    }
    private let settings: [Setting]
    private let defaults = UserDefaults.standard
    private var originals: [String: Bool] = [:]
    private let journal = "screenZoomSuppression.restore.v1"
    private let synchronize: (@convention(c) () -> Void)?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess", RTLD_LAZY | RTLD_LOCAL)
        settings = ["UATrackpadGestureZoom", "UAScrollZoom"].compactMap { name in
            guard let handle, let read = dlsym(handle, name + "IsEnabled"),
                  let write = dlsym(handle, name + "SetEnabled") else { return nil }
            return Setting(name: name, read: unsafeBitCast(read, to: Read.self),
                           write: unsafeBitCast(write, to: Write.self))
        }
        synchronize = handle.flatMap { dlsym($0, "UAPreferencesSynchronize") }
            .map { unsafeBitCast($0, to: (@convention(c) () -> Void).self) }
        // Recover the exact prior switches if a previous process quit abruptly.
        if let saved = defaults.dictionary(forKey: journal) as? [String: Bool] {
            originals = saved
            restore()
        }
    }

    func restore() {
        guard !originals.isEmpty else { return }
        for setting in settings {
            if let original = originals[setting.name] { setting.write(original) }
        }
        synchronize?()
        originals.removeAll()
        defaults.removeObject(forKey: journal)
    }
    deinit { restore() }
}
