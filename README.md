<p align="center">
  <img src="docs/images/icon.png" width="112" alt="Numpad app icon">
</p>

<h1 align="center">Numpad</h1>

<p align="center">
  <strong>Your trackpad. A number pad.</strong><br>
  A native macOS menu bar app for the numbers your keyboard is missing.
</p>

<p align="center">
  <a href="https://github.com/yeonfish6040/Numpad/releases/latest"><img src="https://img.shields.io/github/v/release/yeonfish6040/Numpad?style=flat-square&color=6eefc2" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-222222?style=flat-square&logo=apple&logoColor=white" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon_%2B_Intel-universal-222222?style=flat-square" alt="Apple Silicon and Intel">
  <img src="https://img.shields.io/badge/Swift-native-F05138?style=flat-square&logo=swift&logoColor=white" alt="Built with Swift">
</p>

<p align="center">
  <a href="https://github.com/yeonfish6040/Numpad/releases/latest"><strong>Download for Mac ↓</strong></a>
  &nbsp; · &nbsp; <a href="#get-started">Get started</a>
  &nbsp; · &nbsp; <a href="docs/DEVELOPMENT.md">Build from source</a>
  &nbsp; · &nbsp; <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="docs/images/overlay.jpg" width="780" alt="Numpad’s floating keypad overlay, with numbers and operators laid out across the trackpad">
</p>

Press <kbd>Right ⌘</kbd> + <kbd>Right ⌥</kbd>, tap a number, and keep going. Numpad turns the touch surface you already have into a numeric keypad, with an overlay to guide you and haptics you can feel.

## See it in action

[![Numpad demo: typing numbers and adjusting the keypad layout](docs/images/demo.gif)](https://github.com/yeonfish6040/Numpad/releases/download/v0.0.4/Numpad-demo.mp4)

[Watch the demo ↗](https://github.com/yeonfish6040/Numpad/releases/download/v0.0.4/Numpad-demo.mp4) · 36 seconds of typing and finger calibration, recorded on a Mac.

## A little more keyboard, without more hardware

| | |
| :--- | :--- |
| **Tap to type**<br>Numbers, decimal point, arithmetic operators, Return, and Backspace. A short tap types once when you lift your finger. | **Feel each input**<br>Separate haptics for touch down and confirmed input, plus a stronger guide at the center of `5`. |
| **Make room**<br>Drag the translucent overlay anywhere. Snap to screen edges or center; let it move around the focused input field. | **Pick your side**<br>Place operators on the left or right. Rest one finger and use another for repeated taps. |
| **Keep it local**<br>No accounts, network requests, analytics, or input log files. The app reads field geometry to position the overlay, not field contents. | **Choose your language**<br>English by default, with Korean available in Settings. Switch instantly, without restarting. |

## Get started

1. **[Download the latest DMG](https://github.com/yeonfish6040/Numpad/releases/latest)**, open it, and drag **Numpad** into **Applications**. Release builds are Developer ID signed and notarized by Apple.
2. Open Numpad and allow it under **System Settings → Privacy & Security → Accessibility**. The app lives in your menu bar.
3. Focus a text field, then press and release <kbd>Right ⌘</kbd> + <kbd>Right ⌥</kbd> to turn the keypad on.
4. Tap the position of a key on your trackpad. Press <kbd>Esc</kbd> or the same shortcut to go back to normal.

**Requires macOS 13+ and a Mac trackpad.** Force Touch is required for haptic feedback. The DMG includes Apple Silicon and Intel support.

On first launch, an interactive guide walks through permission, layout, the shortcut, and a safe typing practice. Reopen it anytime from **Getting Started…** in the menu bar. English and Korean can be selected inside the guide.

> While the keypad is on, normal trackpad pointer movement and scrolling are blocked. Physical clicks and click-drag still work. Opening Settings turns the keypad off.

## Settle into your layout

Choose **Settings → General** to change the language or operator position. Drag the overlay to save its location, or use **Reset to Bottom Center** to start fresh.

Choose **Settings → Haptics** to decide which interactions you want to feel.

<p align="center">
  <img src="docs/images/settings-en.jpg" width="46%" alt="General settings with English language selection and keypad layout preview">
  &nbsp;
  <img src="docs/images/haptics-en.jpg" width="46%" alt="Haptic settings for touch down, confirmed taps, and the center guide">
</p>

<details>
<summary><strong>Experimental: fit the keypad to your fingers</strong></summary>

Enable **Settings → Experimental → Calibrate with Finger Positions** to move, rotate, and scale the layout with three fingers. The middle finger anchors `5`; the outer fingers set the angle and scale.

Optional four-finger calibration aligns the middle two fingers with `×` and `−`. Calibration is saved separately for left and right operator layouts, and can be kept between sessions or reset at any time. It is off by default.

Calibration blocks conflicting macOS gestures and temporarily suspends trackpad/scroll zoom settings while active, restoring the previous values when the mode ends. Large adjustments can move keys beyond the trackpad area.

<p align="center">
  <img src="docs/images/calibration-en.jpg" width="500" alt="Experimental finger calibration settings">
</p>

</details>

## Good to know

<details>
<summary><strong>Why is the shortcut not working?</strong></summary>

Use the **right-hand** Command and Option keys, without Shift or Control. Check Accessibility permission and the menu bar icon. Secure Input, sleep, permission loss, or a stopped input monitor turns keypad mode off.

</details>

<details>
<summary><strong>Can I rest a finger on the trackpad?</strong></summary>

Yes. A stationary finger becomes an anchor after about 120 ms, letting another finger tap repeatedly. The anchor does not type. Lifting it or moving it too far cancels the current tap. A single-finger tap on `5` still types normally.

</details>

<details>
<summary><strong>What should I know about compatibility?</strong></summary>

Numpad uses private Apple APIs for trackpad input, some haptics, and experimental zoom control. Compatibility may change with macOS updates. It uses the default trackpad; restart the app after changing connected trackpads.

Physical clicks and tap-to-click are distinguished using pressure and contact timing. A pressureless external mouse used alongside trackpad touches may be treated as tap-to-click. Decimal input and keypad shortcuts follow the receiving app and input settings.

</details>

## Build, explore, contribute

```sh
git clone https://github.com/yeonfish6040/Numpad.git
cd Numpad
swift test
bash scripts/build-app.sh
open dist/Numpad.app
```

Built with Swift, AppKit, and SwiftUI, with no external package dependencies. The [development guide](docs/DEVELOPMENT.md) covers the codebase, localization, diagnostics, and signed DMG builds.

Found a bug or have an idea? [Open an issue](https://github.com/yeonfish6040/Numpad/issues) with your Mac model, macOS version, and steps to reproduce it. Translation improvements are welcome too.
