# Developing Numpad

[← Back to Numpad](../README.md)

## Requirements and builds

Use macOS 13+, Swift 5.9+ and Xcode Command Line Tools.

```sh
swift test
bash scripts/build-app.sh
open dist/Numpad.app
```

The default build targets the current Mac architecture and uses an ad hoc signature for local testing. `UNIVERSAL=1 bash scripts/build-app.sh` includes arm64 and x86_64. `VERSION` is the source of the release version. The executable target remains `TrackpadNumpad`. The app bundle identifier and code-signing identifier are `com.yftech.TrackpadNumpad`. Published releases through 0.0.2 used `dev.yeonfish.TrackpadNumpad`; macOS treats the new identifier as a separate app for preferences and Accessibility permissions.

## Codebase

| Path | Responsibility |
| --- | --- |
| `Sources/CTrackpad` | Load MultitouchSupport, receive normalized touch coordinates, drive haptics |
| `Sources/TrackpadCore` | Key mapping, tap recognition, anchors, calibration, overlay placement and snapping, localization |
| `Sources/TrackpadNumpad` | Per-device input monitoring, configurable shortcut, menu bar, SwiftUI settings and overlay |
| `Tests/TrackpadCoreTests` | Input behavior, calibration, placement, snapping, language defaults and translation catalogs |
| `scripts/build-app.sh` | App bundle, localization resources, icon generation, signing |
| `scripts/build-dmg.sh` | Universal DMG, Applications shortcut, optional notarization, SHA-256 checksums |

## Localization

English is the explicit initial language, even when macOS prefers Korean. The in-app **General → Language** picker persists `appLanguage` as `en` or `ko` and updates settings, menus, window titles, overlay hints, and stored status messages without a restart.

Editable catalogs live in `Sources/TrackpadCore/Resources/{en,ko}.lproj/Localizable.strings`. English source strings are the keys. Keep key sets and `%d` placeholders aligned. `LocalizedMessage` retains the source key and optional finger count so a previous calibration message can be displayed in either language. C bridge errors use English keys and are translated at the app boundary.

SwiftPM builds the resource bundle; the app build script copies it into `Contents/Resources`. Verify translations in the packaged executable:

```sh
dist/Numpad.app/Contents/MacOS/TrackpadNumpad --check-localization
```

## Diagnostics

```sh
# Framework availability, connected trackpads, registry attribution, Accessibility, stream start and stop
dist/Numpad.app/Contents/MacOS/TrackpadNumpad --diagnose

# Start with Settings visible
dist/Numpad.app/Contents/MacOS/TrackpadNumpad --settings

# Open the setup guide, even after completing or dismissing it
dist/Numpad.app/Contents/MacOS/TrackpadNumpad --onboarding

# Show the overlay and quit after two seconds
dist/Numpad.app/Contents/MacOS/TrackpadNumpad --smoke-test

# One haptic pulse and driver result
dist/Numpad.app/Contents/MacOS/TrackpadNumpad --test-haptic
```

`--diagnose` does not open a GUI or request permission. A successful stream start does not verify actual taps or delivery to another app.

The setup guide opens automatically on first launch. Completion or dismissal saves `onboardingCompleted` under `com.yftech.TrackpadNumpad`. Reopen it from **Getting Started…** in the menu bar or use `--onboarding`; no preference reset is needed. Explicit `--settings` and `--smoke-test` launches suppress the automatic guide. Practice input remains inside the guide, and closing it releases its touch stream and input monitor.

## Input behavior

- A valid tap lasts 25–450 ms and types once on release. Swipes, long holds, and extra typing contacts cancel it.
- A stationary contact becomes an anchor after about 120 ms. When two contacts land together, a contact near the center of `5` can anchor immediately. Movement of the anchor by normalized distance 0.08 or its release cancels the current tap until all fingers lift.
- The center detent for `5` uses an ellipse in key-relative coordinates: entry radius 3.5%, exit radius 5.5%. This hysteresis avoids repeated haptics from boundary noise. Landing directly at the center and lifting off are not crossing events.
- Pointer suppression uses Quartz sender field 87, resolved through IORegistry to the Multitouch ID. Only selected device IDs are filtered. Unknown/synthetic senders pass through; contact timing is never used to infer a device. Click pairing and three-finger drag suppression are independent per device. Pressure-zero clicks on selected devices are classified as tap-to-click; physical clicks pass while cancelling that device’s numeric tap.
- A new confirmed input cancels the previous highlight clear task. Highlighting turns on immediately, stays for 160 ms after the latest input, then fades over 80 ms. Reduce Motion disables the fade.
- Three-finger calibration uses `4·5·6`, anchoring `5` to the middle finger. Four-finger calibration uses the middle contacts at `×·−`. Both preserve key proportions through translation, rotation, and uniform scale.

## Signed DMG releases

Install a **Developer ID Application** certificate and private key. Store notarization credentials locally in Keychain:

```sh
xcrun notarytool store-credentials Numpad
```

Then build:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=Numpad \
bash scripts/build-dmg.sh
```

The script enables hardened runtime, timestamps the app signature, notarizes the app, staples its ticket, creates and signs the DMG, notarizes and staples the DMG, and checks Gatekeeper acceptance. Output: `dist/Numpad-<version>-universal.dmg` and its SHA-256 checksum file.

Without signing credentials, `bash scripts/build-dmg.sh` produces a local test DMG with no notarization. Do not publish it as a notarized release. Keep credentials and private keys out of the repository.

## Platform notes

MultitouchSupport, actuators, Quartz sender field 87, and legacy UniversalAccess recovery calls are private Apple APIs. This project does not target App Store distribution. Devices are enumerated with `MTDeviceCreateList` and matched to HID touchpad usage/acceleration in IORegistry, excluding Magic Mouse and Touch Bar. Connection changes are detected by polling once a second, close onboarding practice, and safely disable keypad mode before refreshing the list. Selection uses a built-in identifier or external serial number when available, with a Multitouch-ID fallback. Identifiers can change on reconnect for devices without stable serial numbers.

Each selected trackpad has independent tap, center feedback, calibration gesture, and transform state, including overlapping contact IDs across devices. Haptics target the touch device. The overlay shows the latest device to send a frame. Calibration is stored per device, operator side, and key permutation. Default built-in calibration migrates from the old preference key.

No new session alters global screen/scroll zoom preferences. Startup only recovers an old release’s pending restoration journal. Events that cannot be attributed to a selected device pass through, so system gestures/zoom that lack source attribution may still activate. Two-trackpad hardware validation is required before claiming full device/OS compatibility.

`Keyboard` settings record a modifier-plus-key shortcut, retain the original right Command/Option chord as the default, and keep Escape reserved. A custom activation key’s down/repeat/up are consumed, and recording suspends global activation. Key arrangements are validated permutations of the 17 existing outputs over fixed slots; each operator side persists separately. Overlay rendering, hit testing, center feedback, and calibration consume the same arranged keys.

Signing identity or installation location changes can affect Accessibility permissions. If access fails after a local rebuild, remove and re-add the app in System Settings.

## API references

- [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport)
- [Multitouch ABI](https://github.com/ZaynJarvis/trackpad-studio/blob/master/Sources/CMultitouchShim/include/CMultitouchShim.h)
- [Actuator example](https://gist.github.com/niw/b120b460e854ec10cefeeb60784f5dbb)
- [Apple CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)
- [Apple haptics](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer)

- [Quartz sender attribution reference](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Utility/EventUtility.m)
