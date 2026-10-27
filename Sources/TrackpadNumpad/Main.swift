import AppKit
import CTrackpad
import TrackpadCore

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--check-localization") {
            let settingsKey = "app.ui.settings"
            let startKey = "app.ui.get_started"
            let english = AppLocalization.text(settingsKey, language: .english)
            let korean = AppLocalization.text(settingsKey, language: .korean)
            let japanese = AppLocalization.text(settingsKey, language: .japanese)
            let koreanOnboarding = AppLocalization.text(startKey, language: .korean)
            let japaneseOnboarding = AppLocalization.text(startKey, language: .japanese)
            print("English: \(english)\nKorean: \(korean)\nJapanese: \(japanese)")
            exit(english == "Settings…" && korean == "설정…" && japanese == "設定…"
                 && koreanOnboarding == "시작하기" && japaneseOnboarding == "はじめる" ? 0 : 1)
        }
        if CommandLine.arguments.contains("--test-haptic") {
            let success = TPHapticClick()
            TPHapticShutdown()
            print("Haptic pulse: \(success ? "OK" : "unavailable")")
            exit(success ? 0 : 1)
        }
        if CommandLine.arguments.contains("--diagnose") {
            let ready = TPInitialize()
            print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("MultitouchSupport / trackpads: \(ready ? "OK" : AppLocalization.text(String(cString: TPError())))")
            for device in TrackpadDevice.connected() {
                print("Trackpad: \(device.displayName), id=\(device.id), registry=\(device.registryID), built-in=\(device.builtIn)")
                print("Sender attribution: \(TPDeviceIDForSender(device.registryID) == device.id ? "OK" : "unavailable")")
            }
            print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
            if ready {
                let started = TPStart({ _, _, _, _ in }, nil)
                print("Touch stream start: \(started ? "OK" : AppLocalization.text(String(cString: TPError())))")
                TPStop()
                print("Touch stream stop: OK")
                if !started { exit(1) }
            }
            exit(ready ? 0 : 1)
        }
        let app = NSApplication.shared
        // A non-Dock app can keep the text cursor in the user's destination application.
        app.setActivationPolicy(.accessory)
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
