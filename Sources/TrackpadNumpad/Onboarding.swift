import AppKit
import Combine
import SwiftUI
import CTrackpad
import TrackpadCore


private func pause(_ seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, permission, layout, shortcut, practice, done
}

final class OnboardingModel: ObservableObject {
    @Published private(set) var step = OnboardingStep.welcome
    @Published private(set) var forward = true
    @Published private(set) var leftCommand = false
    @Published private(set) var leftOption = false
    @Published private(set) var rightCommand = false
    @Published private(set) var rightOption = false
    @Published private(set) var shortcutDone = false
    @Published private(set) var wrongSide = 0
    @Published private(set) var typed = ""
    @Published private(set) var touches: [CGPoint] = []
    @Published private(set) var flash: UInt16?
    @Published private(set) var mistakes = 0
    @Published private(set) var practiceDone = false
    @Published private(set) var practiceAvailable = true
    let target = "2026"
    let app: AppController
    var onFinish: (() -> Void)?
    var onFocus: (() -> Void)?
    private var monitor: Any?
    private var chord = ModifierShortcutMatcher()
    private var stream: TouchStream?
    private let input = InputService()
    private var recognizer = AnchoredTapRecognizer()
    private var trustObserver: AnyCancellable?
    private var active = true
    private var flashClearWork: DispatchWorkItem?

    init(app: AppController) {
        self.app = app
        trustObserver = app.$trusted.removeDuplicates().dropFirst().sink { [weak self] trusted in
            guard let self, self.active, trusted, self.step == .permission else { return }
            self.onFocus?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                if self?.active == true, self?.step == .permission { self?.next() }
            }
        }
    }

    var nextKey: PadKey? {
        guard typed.count < target.count else { return nil }
        let label = String(target[target.index(target.startIndex, offsetBy: typed.count)])
        return app.keypadKeys.first { $0.label == label }
    }

    func next() {
        guard let following = OnboardingStep(rawValue: step.rawValue + 1) else { finish(); return }
        go(following)
    }

    func back() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { go(previous) }
    }

    func go(_ destination: OnboardingStep) {
        guard active, destination != step else { return }
        // Commit the direction before the step changes so both transitions agree.
        forward = destination.rawValue > step.rawValue
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, destination != step else { return }
            leave(step)
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.55, dampingFraction: 0.86)) {
                self.step = destination
            }
            enter(destination)
        }
    }

    func finish() {
        OnboardingState.complete()
        tearDown()
        onFinish?()
    }

    func tearDown() {
        guard active else { return }
        active = false
        leave(step)
        flashClearWork?.cancel()
        flashClearWork = nil
    }

    private func enter(_ step: OnboardingStep) {
        switch step {
        case .shortcut:
            chord.reset(); shortcutDone = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .flagsChanged { self.flagsChanged(UInt64(event.modifierFlags.rawValue)) }
                else if self.app.activationShortcut.matches(keyCode: event.keyCode,
                    flags: UInt64(event.modifierFlags.rawValue), isRepeat: event.isARepeat) {
                    self.shortcutPressed(); return nil
                }
                return event
            }
        case .practice: startPractice()
        default: break
        }
    }

    private func leave(_ step: OnboardingStep) {
        switch step {
        case .shortcut:
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            leftCommand = false; leftOption = false; rightCommand = false; rightOption = false
        case .practice: stopPractice()
        default: break
        }
    }

    // MARK: Shortcut

    /// Device-dependent modifier bits from IOLLEvent.h distinguish left and right keys.
    private func flagsChanged(_ flags: UInt64) {
        guard app.activationShortcut.isModifierOnly else { return }
        let wasLeft = leftCommand && leftOption
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) {
            rightCommand = flags & 0x10 != 0; rightOption = flags & 0x40 != 0
            leftCommand = flags & 0x08 != 0; leftOption = flags & 0x20 != 0
        }
        if app.activationShortcut.isDefault && leftCommand && leftOption && !wasLeft && !shortcutDone { wrongSide += 1 }
        if chord.update(flags: flags, shortcut: app.activationShortcut) { shortcutPressed() }
    }

    /// Also called from the global activation shortcut while onboarding is open.
    func shortcutPressed() {
        guard active, step == .shortcut, !shortcutDone else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shortcutDone = true }
        app.playHaptic(strong: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.active == true, self?.step == .shortcut { self?.next() }
        }
    }

    // MARK: Practice

    private func startPractice() {
        guard stream == nil else { return }
        typed = ""; practiceDone = false; touches = []
        recognizer = AnchoredTapRecognizer(layout: app.controlSide, keys: app.keypadKeys)
        recognizer.reset(waitForLift: true)
        app.refreshTrackpads()
        guard TPInitialize(), let deviceID = app.selectedDeviceIDs.first else { practiceAvailable = false; return }
        input.selectedDeviceIDs = [deviceID]
        // Hold the pointer still like the real mode so taps never click this window.
        if AXIsProcessTrusted() {
            input.onEscape = { [weak self] in self?.next() }
            input.onFailure = { [weak self] in self?.input.stop() }
            _ = input.start()
        }
        let created = TouchStream(deviceIDs: [deviceID]) { [weak self] _, touches, timestamp in self?.receive(touches, at: timestamp) }
        if created.start() { stream = created; practiceAvailable = true } else { practiceAvailable = false; input.stop() }
    }

    private func stopPractice() {
        input.stop()
        stream?.stop(); stream = nil
        touches = []; flash = nil
        flashClearWork?.cancel()
        flashClearWork = nil
    }

    private func receive(_ touches: [Touch], at timestamp: Double) {
        guard active, step == .practice, stream != nil else { return }
        self.touches = touches.map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
        if let deviceID = app.selectedDeviceIDs.first { input.updateTouches(touches, deviceID: deviceID) }
        let key = recognizer.process(touches, at: timestamp, suppressInput: practiceDone)
        if recognizer.beganKey != nil && !practiceDone { app.playHaptic() }
        guard let key, !practiceDone else { return }
        withAnimation(.easeOut(duration: 0.08)) { flash = key.id }
        flashClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.step == .practice else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.flash = nil }
            self.flashClearWork = nil
        }
        flashClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        if key.label == "⌫" {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = typed.popLast() }
        } else if key.id == nextKey?.id {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { typed.append(key.label) }
            app.playHaptic()
            if typed == target {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { practiceDone = true }
                app.playHaptic(strong: true)
            }
        } else {
            mistakes += 1
        }
    }
}

// MARK: - Root

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var app: AppController

    var body: some View {
        ZStack {
            AuroraBackground(step: model.step)
            VStack(spacing: 0) {
                ProgressDots(step: model.step).padding(.top, 20)
                ZStack {
                    stepView
                        .id("\(model.step.rawValue)-\(app.language.rawValue)")
                        .transition(.step(forward: model.forward))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer.padding(.horizontal, 32).padding(.bottom, 26)
            }
        }
        .frame(width: 820, height: 580)
        .overlay(alignment: .topTrailing) {
            Picker(L("app.ui.language"), selection: $app.language) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.name).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .padding(.top, 14).padding(.trailing, 22)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .permission: PermissionStep(trusted: app.trusted)
        case .layout: LayoutStep(app: app)
        case .shortcut: ShortcutStep(model: model)
        case .practice: PracticeStep(model: model, layout: app.controlSide)
        case .done: DoneStep(shortcut: app.shortcutTitle)
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.step {
        case .welcome:
            PrimaryButton(title: L("app.ui.get_started"), systemImage: "arrow.right") { model.next() }
        case .done:
            PrimaryButton(title: L("app.ui.start_using_numpad"), systemImage: "checkmark") { model.finish() }
        default:
            HStack {
                QuietButton(title: L("app.ui.back")) { model.back() }
                Spacer()
                if skippable { QuietButton(title: L("app.ui.skip")) { model.next() }.padding(.trailing, 8) }
                PrimaryButton(title: primaryTitle, systemImage: primaryImage, enabled: primaryEnabled) {
                    if model.step == .permission && !app.trusted { app.requestPermission() } else { model.next() }
                }
            }
        }
    }

    private var skippable: Bool {
        switch model.step {
        case .permission: return !app.trusted
        case .shortcut: return !model.shortcutDone
        case .practice: return !model.practiceDone
        default: return false
        }
    }
    private var primaryTitle: String {
        model.step == .permission && !app.trusted ? L("app.ui.open_system_settings") : L("app.ui.continue")
    }
    private var primaryImage: String {
        model.step == .permission && !app.trusted ? "arrow.up.forward.app" : "arrow.right"
    }
    private var primaryEnabled: Bool {
        switch model.step {
        case .shortcut: return model.shortcutDone
        case .practice: return model.practiceDone
        default: return true
        }
    }
}

// MARK: - Steps

private struct StepTitle: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mint)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(mint.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(mint.opacity(0.25), lineWidth: 1))
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            Text(subtitle)
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.58))
                .lineSpacing(3)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: alignment == .center ? .center : .leading)
        }
    }
}

private struct WelcomeStep: View {
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 34) {
            HeroPad()
                .frame(width: 440, height: 250)
                .padding(.top, 8)
            VStack(spacing: 12) {
                Text(L("app.ui.your_trackpad_now_a_numpad"))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, mint], startPoint: .leading, endPoint: .trailing))
                Text(L("app.ui.lives_in_your_menu_bar_one_shortcut_turns_your_trackpad_into_a_numeric_keypad_right_at_your_fingertips"))
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
        }
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.7).delay(reduceMotion ? 0 : 0.9)) { appeared = true }
        }
    }
}

/// A tilted trackpad that turns into a keypad and types on its own.
private struct HeroPad: View {
    @State private var revealed = 0
    @State private var lit: UInt16?
    @State private var finger: CGPoint?
    private let layout = KeypadLayout.right

    var body: some View {
        ZStack {
            Ellipse().fill(mint.opacity(0.28)).frame(width: 380, height: 80).blur(radius: 50).offset(y: 120)
            PadSurface(layout: layout, revealed: revealed, highlighted: lit,
                       touches: finger.map { [$0] } ?? [], labelSize: 20)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : 18), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.55)
        }
        .task { await run() }
    }

    private func run() async {
        if reduceMotion { revealed = layout.keys.count; return }
        do {
            try await pause(0.25)
            for index in 1...layout.keys.count {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { revealed = index }
                try await pause(0.04)
            }
            try await pause(0.6)
            while !Task.isCancelled {
                for label in ["1", "2", "8", "+", "4", "0", "↵"] {
                    let point = layout.center(of: label)
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { finger = CGPoint(x: point.x, y: point.y) }
                    try await pause(0.42)
                    withAnimation(.easeOut(duration: 0.06)) { lit = layout.keys.first { $0.label == label }?.id }
                    try await pause(0.16)
                    withAnimation(.easeOut(duration: 0.25)) { lit = nil }
                    try await pause(0.18)
                }
                withAnimation(.easeOut(duration: 0.3)) { finger = nil }
                try await pause(1.2)
            }
        } catch {}
    }
}

private struct PermissionStep: View {
    var trusted: Bool
    var body: some View {
        HStack(spacing: 48) {
            SettingsIllustration(granted: trusted)
                .frame(width: 300)
            VStack(alignment: .leading, spacing: 22) {
                StepTitle(eyebrow: L("app.ui.permission"), title: L("app.ui.allow_accessibility_access_2"),
                          subtitle: L("app.ui.numpad_needs_permission_to_hold_the_pointer_still_and_send_numbers_to_the_app_you_are_using_it_does_not_read_or_save_your_input"),
                          alignment: .leading)
                StatusPill(granted: trusted)
                VStack(alignment: .leading, spacing: 10) {
                    Instruction(number: 1, text: L("app.ui.click_open_system_settings"))
                    Instruction(number: 2, text: L("app.ui.enable_numpad_in_the_list"))
                    Instruction(number: 3, text: L("app.ui.you_will_return_here_once_access_is_granted"))
                }
            }
            .frame(width: 340, alignment: .leading)
        }
    }
}

private struct Instruction: View {
    var number: Int
    var text: String
    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.08), in: Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.72))
        }
    }
}

/// A miniature System Settings pane whose switch demonstrates the action to take.
private struct SettingsIllustration: View {
    var granted: Bool
    @State private var demoOn = false

    var body: some View {
        let on = granted || demoOn
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 9, height: 9) }
                Spacer()
                Text(L("app.ui.accessibility")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            .padding(12)
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                placeholderRow(width: 90)
                Divider().opacity(0.25).padding(.leading, 48)
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 26, height: 26)
                    Text("Numpad").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Capsule().fill(on ? mint : Color.white.opacity(0.18))
                        .frame(width: 34, height: 20)
                        .overlay(alignment: on ? .trailing : .leading) {
                            Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(mint.opacity(granted ? 0.08 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(mint.opacity(granted ? 0 : 0.35), lineWidth: 1).padding(2))
                Divider().opacity(0.25).padding(.leading, 48)
                placeholderRow(width: 120)
            }
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .background(LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
        .rotation3DEffect(.degrees(reduceMotion ? 0 : -8), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: on)
        .task {
            guard !reduceMotion else { return }
            do {
                while !Task.isCancelled {
                    try await pause(1.1); demoOn = true
                    try await pause(1.6); demoOn = false
                }
            } catch {}
        }
    }

    private func placeholderRow(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)).frame(width: 26, height: 26)
            RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.1)).frame(width: width, height: 8)
            Spacer()
            Capsule().fill(.white.opacity(0.12)).frame(width: 34, height: 20)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

private struct LayoutStep: View {
    @ObservedObject var app: AppController
    var body: some View {
        VStack(spacing: 32) {
            StepTitle(eyebrow: L("app.ui.layout"), title: L("app.ui.which_side_feels_right"),
                      subtitle: L("app.ui.choose_a_side_for_backspace_divide_multiply_minus_return_you_can_change_it_in_settings_anytime"))
            HStack(spacing: 22) {
                LayoutCard(layout: .left, title: L("app.ui.left"), selected: app.controlSide == .left) { app.controlSide = .left }
                LayoutCard(layout: .right, title: L("app.ui.right"), selected: app.controlSide == .right) { app.controlSide = .right }
            }
        }
    }
}

private struct ShortcutStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        VStack(spacing: 40) {
            StepTitle(eyebrow: L("app.ui.shortcut"), title: L("app.ui.one_shortcut_on_or_off"),
                      subtitle: model.app.activationShortcut.isDefault ? L("app.ui.press_command_command_and_option_option_together_on_the_right_of_the_space_bar") : L("app.ui.press_your_activation_shortcut"))
            if !model.app.activationShortcut.isDefault {
                Text(model.app.shortcutTitle).font(.system(size: 36, weight: .semibold, design: .rounded))
                    .padding(24).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            } else {
            HStack(alignment: .bottom, spacing: 7) {
                Keycap(symbol: "fn", name: "", width: 52, dim: true)
                Keycap(symbol: "⌃", name: "control", width: 58, dim: true)
                Keycap(symbol: "⌥", name: "option", width: 58, pressed: model.leftOption, dim: true)
                Keycap(symbol: "⌘", name: "command", width: 74, pressed: model.leftCommand, dim: true)
                Keycap(symbol: "", name: "", width: 230, dim: true)
                Keycap(symbol: "⌘", name: "command", width: 74, pressed: model.rightCommand, highlight: true, done: model.shortcutDone)
                Keycap(symbol: "⌥", name: "option", width: 58, pressed: model.rightOption, highlight: true, done: model.shortcutDone)
            }
            .modifier(Shake(animatableData: CGFloat(model.wrongSide)))
            .animation(.linear(duration: 0.4), value: model.wrongSide)
            }
            Group {
                if model.shortcutDone {
                    Label(L("app.ui.got_it_you_can_now_turn_on_the_keypad_in_any_app"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(mint)
                } else if model.app.activationShortcut.isDefault && (model.leftCommand || model.leftOption) {
                    Label(L("app.ui.those_are_the_left_keys_try_the_right_command_and_option_keys"), systemImage: "hand.point.right.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text(L("app.ui.use_the_same_shortcut_or_press_esc_to_turn_the_keypad_off")).foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .transition(.opacity.combined(with: .offset(y: 6)))
            .animation(.easeOut(duration: 0.2), value: model.shortcutDone)
            .animation(.easeOut(duration: 0.2), value: model.leftCommand || model.leftOption)
        }
    }
}

private struct PracticeStep: View {
    @ObservedObject var model: OnboardingModel
    var layout: KeypadLayout

    var body: some View {
        HStack(spacing: 44) {
            ZStack {
                PadSurface(layout: layout, keys: model.app.keypadKeys, highlighted: model.flash, target: model.practiceDone ? nil : model.nextKey?.id,
                           touches: model.touches, labelSize: 20)
                    .aspectRatio(PadGeometry.aspectRatio, contentMode: .fit)
                    .frame(width: 380)
                if !model.practiceAvailable {
                    Label(L("app.ui.no_trackpad_found"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.75), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                StepTitle(eyebrow: L("app.ui.practice"), title: model.practiceDone ? L("app.ui.you_have_got_it") : L("app.ui.try_it_for_yourself"),
                          subtitle: String(format: L("app.ui.tap_briefly_with_one_finger_to_enter_value_practice_stays_in_this_guide_and_never_types_into_another_app"), model.target),
                          alignment: .leading)
                DigitDisplay(target: model.target, typed: model.typed, done: model.practiceDone)
                    .modifier(Shake(animatableData: CGFloat(model.mistakes)))
                    .animation(.linear(duration: 0.35), value: model.mistakes)
                VStack(alignment: .leading, spacing: 8) {
                    Tip(symbol: "delete.left", text: L("app.ui.tap_backspace_to_delete_a_digit"))
                    Tip(symbol: "hand.raised", text: L("app.ui.rest_one_finger_to_use_it_as_an_anchor"))
                    Tip(symbol: "escape", text: L("app.ui.press_esc_to_skip_this_step"))
                }
            }
            .frame(width: 300, alignment: .leading)
        }
        .overlay { if model.practiceDone { ConfettiBurst() } }
    }
}

private struct DigitDisplay: View {
    var target: String
    var typed: String
    var done: Bool

    var body: some View {
        let digits = Array(typed)
        HStack(spacing: 8) {
            ForEach(0..<target.count, id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(index < digits.count ? 0.09 : 0.035))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(done ? mint : (index == digits.count ? mint.opacity(0.7) : .white.opacity(0.08)), lineWidth: 1))
                    if index < digits.count {
                        Text(String(digits[index]))
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(done ? mint : .white)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else if index == digits.count {
                        BlinkingCaret()
                    }
                }
                .frame(width: 52, height: 62)
            }
        }
        .shadow(color: mint.opacity(done ? 0.35 : 0), radius: 20)
    }
}

private struct Tip: View {
    var symbol: String
    var text: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 16).foregroundStyle(mint.opacity(0.8))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct DoneStep: View {
    var shortcut: String
    @State private var drawn = false
    var body: some View {
        VStack(spacing: 30) {
            ZStack {
                Circle().fill(mint.opacity(0.18)).frame(width: 150).blur(radius: 30)
                Circle().stroke(.white.opacity(0.08), lineWidth: 3).frame(width: 96)
                Circle().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(mint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 96)
                CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(mint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 30)
            }
            .frame(height: 110)
            StepTitle(eyebrow: L("app.ui.all_set"), title: L("app.ui.numbers_at_your_fingertips"),
                      subtitle: L("app.ui.numpad_is_ready_in_your_menu_bar_focus_an_input_field_and_press_the_shortcut_to_start_typing_numbers"))
            HStack(spacing: 14) {
                SummaryCard(symbol: "command", title: shortcut, caption: L("app.ui.toggle_on_or_off"))
                SummaryCard(symbol: "escape", title: "Esc", caption: L("app.ui.turn_off_instantly"))
                SummaryCard(symbol: "rectangle.grid.3x3", title: L("app.ui.menu_bar"), caption: L("app.ui.settings_and_preview"))
            }
        }
        .overlay { ConfettiBurst() }
        .onAppear {
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.8).delay(reduceMotion ? 0 : 0.2)) { drawn = true }
        }
    }
}

private struct SummaryCard: View {
    var symbol: String
    var title: String
    var caption: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(mint)
                .frame(width: 40, height: 40).background(mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 150, height: 120)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}


/// Keypad drawn as a trackpad surface. Touch points use bottom-left normalized coordinates.
private struct StepTransition: ViewModifier {
    var offset: CGFloat
    var blur: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.offset(x: offset).blur(radius: blur).opacity(opacity)
    }
}

private extension AnyTransition {
    static func step(forward: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        let identity = StepTransition(offset: 0, blur: 0, opacity: 1)
        return .asymmetric(
            insertion: .modifier(active: StepTransition(offset: forward ? 70 : -70, blur: 14, opacity: 0), identity: identity),
            removal: .modifier(active: StepTransition(offset: forward ? -70 : 70, blur: 14, opacity: 0), identity: identity))
    }
}
