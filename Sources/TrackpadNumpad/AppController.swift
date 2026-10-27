import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import QuartzCore
import CTrackpad
import TrackpadCore

final class AppController: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var deviceReady = false
    @Published private var messageText = LocalizedMessage("Turn your trackpad into a numeric keypad.")
    var message: String { messageText.text(language: language) }
    @Published var language = AppLanguage.load() {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
            settingsWindow?.title = L("Numpad Settings")
            onboardingWindow?.title = L("Welcome to Numpad")
            panel?.title = L("Numpad Overlay")
            mirrorPanels.values.forEach { $0.title = L("Numpad Overlay") }
            if item != nil { updateMenu() }
        }
    }
    @Published private(set) var highlighted: UInt16?
    @Published private(set) var lastKey = "—"
    @Published private(set) var touches: [Touch] = []
    @Published private(set) var overlaySnapPreview: OverlaySnapResult?
    @Published private(set) var overlaySnapBounds = CGRect.zero
    @Published var controlSide = KeypadLayout(rawValue: UserDefaults.standard.string(forKey: "controlSide") ?? "left") ?? .left {
        didSet {
            guard oldValue != controlSide else { return }
            UserDefaults.standard.set(controlSide.rawValue, forKey: "controlSide")
            arrangement = KeyArrangement.load(layout: controlSide)
        }
    }
    @Published var arrangement = KeyArrangement.load(layout: KeypadLayout(rawValue: UserDefaults.standard.string(forKey: "controlSide") ?? "left") ?? .left) {
        didSet {
            arrangement.save(layout: controlSide)
            disable()
            configurationChanged()
        }
    }
    var keypadKeys: [PadKey] { arrangement.keys(for: controlSide) }
    @Published var activationShortcut = KeyboardShortcut.load() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(activationShortcut), forKey: "activationShortcut")
            optionShortcut.configuration = activationShortcut
            if item != nil { updateMenu() }
        }
    }
    @Published private(set) var shortcutProblem: String?
    func setActivationShortcut(_ shortcut: TrackpadCore.KeyboardShortcut) -> String? {
        if let problem = ShortcutAvailability.problem(shortcut) { return problem }
        activationShortcut = shortcut
        return nil
    }
    var recordingShortcut = false { didSet { optionShortcut.suspended = recordingShortcut } }
    var shortcutTitle: String { activationShortcut.displayName }
    @Published private(set) var trackpads: [TrackpadDevice] = []
    @Published private(set) var enabledTrackpads = Set(UserDefaults.standard.stringArray(forKey: "enabledTrackpads") ?? [])
    @Published private(set) var currentDeviceID: UInt64 = 0
    private struct DeviceSession {
        var recognizer: AnchoredTapRecognizer
        var center: CenterCrossingFeedback
        var gesture = InteractiveCalibrationGesture()
        var touches: [Touch] = []
        var transform = PadTransform.identity
        var hasCalibration = false
        var text = LocalizedMessage("No calibration yet.")
        var tracking = false
        var baseline: (transform: PadTransform, has: Bool, status: LocalizedMessage)?
    }
    private var deviceSessions: [UInt64: DeviceSession] = [:]
    var selectedDeviceIDs: [UInt64] { trackpads.filter { enabledTrackpads.contains($0.persistentID) }.map(\.id) }

    func setTrackpad(_ device: TrackpadDevice, enabled: Bool) {
        disable()
        if enabled { enabledTrackpads.insert(device.persistentID) }
        else { enabledTrackpads.remove(device.persistentID) }
        UserDefaults.standard.set(Array(enabledTrackpads), forKey: "enabledTrackpads")
    }

    func refreshTrackpads() {
        if enabled { disable() }
        trackpads = TrackpadDevice.connected(refresh: true)
        deviceReady = !trackpads.isEmpty
        // Keep the original single-device experience on first use. Devices
        // connected later stay unselected until the user opts in.
        if UserDefaults.standard.object(forKey: "enabledTrackpads") == nil, let first = trackpads.first(where: { $0.builtIn }) ?? trackpads.first {
            enabledTrackpads = [first.persistentID]
            UserDefaults.standard.set(Array(enabledTrackpads), forKey: "enabledTrackpads")
        }
        currentDeviceID = selectedDeviceIDs.first ?? trackpads.first?.id ?? 0
        configurationChanged()
    }

    func selectCalibrationDevice(_ id: UInt64) {
        guard !enabled, trackpads.contains(where: { $0.id == id }) else { return }
        currentDeviceID = id
        configurationChanged()
    }

    @Published var experimentalCalibration = UserDefaults.standard.bool(forKey: "experimentalCalibration") {
        didSet {
            UserDefaults.standard.set(experimentalCalibration, forKey: "experimentalCalibration")
            input.blocksSystemGestures = enabled && experimentalCalibration
            configurationChanged()
        }
    }
    @Published var calibrationTiming = CalibrationTiming(rawValue: UserDefaults.standard.string(forKey: "calibrationTiming") ?? "touchDown") ?? .touchDown {
        didSet {
            UserDefaults.standard.set(calibrationTiming.rawValue, forKey: "calibrationTiming")
            configurationChanged()
        }
    }
    @Published private(set) var calibrationTracking = false
    private var calibrationBaseline: (transform: PadTransform, has: Bool, status: LocalizedMessage)?
    @Published var keepCalibrationOnReactivate = UserDefaults.standard.object(forKey: "keepCalibrationOnReactivate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepCalibrationOnReactivate, forKey: "keepCalibrationOnReactivate") }
    }
    @Published var fourFingerCalibration = UserDefaults.standard.bool(forKey: "fourFingerCalibration") {
        didSet {
            UserDefaults.standard.set(fourFingerCalibration, forKey: "fourFingerCalibration")
            calibrationGesture.reset(waitForLift: !touches.isEmpty)
            recognizer.reset(waitForLift: !touches.isEmpty)
        }
    }
    @Published private(set) var calibrationTransform = PadTransform.identity
    @Published private(set) var hasCalibration = false
    @Published private var calibrationText = LocalizedMessage("No calibration yet.")
    var calibrationStatus: String { calibrationText.text(language: language) }
    var effectiveTransform: PadTransform { experimentalCalibration ? calibrationTransform : .identity }
    @Published var hapticsEnabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }
    @Published var hapticTouchDown = UserDefaults.standard.object(forKey: "hapticTouchDown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticTouchDown, forKey: "hapticTouchDown") }
    }
    @Published var hapticInputConfirmed = UserDefaults.standard.object(forKey: "hapticInputConfirmed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticInputConfirmed, forKey: "hapticInputConfirmed") }
    }
    @Published var hapticFiveEnter = UserDefaults.standard.object(forKey: "hapticFiveEnter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticFiveEnter, forKey: "hapticFiveEnter") }
    }
    @Published var hapticFiveExit = UserDefaults.standard.object(forKey: "hapticFiveExit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticFiveExit, forKey: "hapticFiveExit") }
    }
    @Published var hapticCalibration = UserDefaults.standard.object(forKey: "hapticCalibration") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticCalibration, forKey: "hapticCalibration") }
    }
    @Published var sound = UserDefaults.standard.object(forKey: "sound") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sound, forKey: "sound") }
    }
    @Published var showGuide = UserDefaults.standard.object(forKey: "showGuide") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showGuide, forKey: "showGuide")
            if enabled { updateGuide() }
        }
    }
    @Published var overlayOpacity = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    @Published var showOnAllDisplays = UserDefaults.standard.object(forKey: "showOnAllDisplays") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(showOnAllDisplays, forKey: "showOnAllDisplays")
            if panel?.isVisible == true { updateGuide() }
        }
    }
    private var item: NSStatusItem!
    private var panel: NSPanel?
    private var mirrorPanels: [UInt32: NSPanel] = [:]
    private var snapPanel: OverlayPanel?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboarding: OnboardingModel?
    private var calibrationGesture = InteractiveCalibrationGesture()
    private let optionShortcut = ActivationShortcut()
    private let input = InputService()
    private var stream: TouchStream?
    private var recognizer = AnchoredTapRecognizer()
    private var centerFeedback = CenterCrossingFeedback()
    private var generation = 0
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var activationInput: FocusedInput?
    private var screenObserver: NSObjectProtocol?
    private var overlayDragging = false
    private var previewRevision = 0
    private var highlightClearWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Recover only a journal left by an older release. New sessions never
        // change system-wide zoom preferences, which affect unselected devices.
        _ = ScreenZoomSuppression()
        refreshTrackpads()
        optionShortcut.onProblem = { [weak self] in self?.shortcutProblem = $0 }
        optionShortcut.configuration = activationShortcut
        deviceReady = TPInitialize()
        if !deviceReady { messageText = LocalizedMessage(String(cString: TPError())) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenu()
        input.onEscape = { [weak self] in self?.disable() }
        input.onPhysicalClick = { [weak self] deviceID in
            guard let self else { return }
            if deviceID == self.currentDeviceID { self.recognizer.cancelCurrentTap() }
            else { self.deviceSessions[deviceID]?.recognizer.cancelCurrentTap() }
        }
        optionShortcut.action = { [weak self] in
            guard let self else { return }
            if let onboarding = self.onboarding, self.onboardingWindow?.isVisible == true {
                onboarding.shortcutPressed()
                return
            }
            self.toggle()
        }
        optionShortcut.start()
        input.onFailure = { [weak self] in
            self?.disable()
            self?.messageText = LocalizedMessage("Input monitoring stopped, so the keypad was turned off. Turn it on again to continue.")
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.optionShortcut.refreshAvailability()
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.previousApp = app }
            if let panel = self?.panel, panel.isVisible, panel.alphaValue > 0.01 {
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                panel.orderFrontRegardless()
            }
            self?.mirrorPanels.values.filter { $0.isVisible && $0.alphaValue > 0.01 }.forEach {
                $0.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                $0.orderFrontRegardless()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.disable() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if TPDevicesChanged() {
                let wasEnabled = self.enabled
                self.onboardingWindow?.close()
                self.refreshTrackpads()
                if wasEnabled { self.messageText = LocalizedMessage("Trackpad connections changed. Check your devices and turn the keypad on again.") }
            }
            let wasTrusted = self.trusted
            self.trusted = AXIsProcessTrusted()
            if wasTrusted != self.trusted { self.updateMenu() }
            if self.trusted { self.optionShortcut.start() } else { self.optionShortcut.stop() }
            if self.enabled && !self.trusted { self.disable(); self.messageText = LocalizedMessage("Please allow Accessibility access again.") }
            // Secure input must not leave the pointer trapped if Escape is unavailable.
            if self.enabled && IsSecureEventInputEnabled() { self.disable(); self.messageText = LocalizedMessage("The keypad is paused while Secure Input is active.") }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel?.isVisible == true, !self.overlayDragging else { return }
            self.updateGuide()
        }
        if OnboardingState.shouldPresent(arguments: CommandLine.arguments) {
            showOnboarding()
        } else if CommandLine.arguments.contains("--settings") {
            showSettings()
        }
        if CommandLine.arguments.contains("--smoke-test") { previewGuide() }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    @objc func toggle() {
        if enabled { disable(); return }
        // The guide's practice step must release its stream before real input starts.
        onboardingWindow?.close()
        trusted = AXIsProcessTrusted()
        guard trusted else {
            messageText = LocalizedMessage("Allow Accessibility access, then turn the keypad on again.")
            requestPermission(); return
        }
        guard !IsSecureEventInputEnabled() else { messageText = LocalizedMessage("Turn the keypad on again after leaving Secure Input."); return }
        refreshTrackpads()
        deviceReady = TPInitialize()
        guard !selectedDeviceIDs.isEmpty else {
            messageText = LocalizedMessage("Select a trackpad in Settings before turning on the keypad.")
            showSettings(); return
        }
        guard deviceReady else { messageText = LocalizedMessage(String(cString: TPError())); showSettings(); return }
        activationInput = FocusedInput.capture(applicationPID: NSApp.isActive ? previousApp?.processIdentifier : nil)
        input.selectedDeviceIDs = Set(selectedDeviceIDs)
        guard input.start() else {
            messageText = LocalizedMessage("Could not start input monitoring. Check Accessibility access and restart Numpad.")
            showSettings(); return
        }
        generation += 1
        let session = generation
        deviceSessions.removeAll()
        currentDeviceID = 0
        for id in selectedDeviceIDs {
            selectDeviceSession(id)
            recognizer.reset(); centerFeedback.reset(); calibrationGesture.reset()
            if !keepCalibrationOnReactivate {
                calibrationTransform = .identity; hasCalibration = false
            }
        }
        saveDeviceSession()
        // Ignore the click/finger used to enable the mode, including delayed framework frames.
        let readyAt = ProcessInfo.processInfo.systemUptime + 0.25
        stream = TouchStream(deviceIDs: selectedDeviceIDs) { [weak self] deviceID, touches, timestamp in
            guard let self, self.enabled, self.generation == session else { return }
            self.selectDeviceSession(deviceID)
            self.touches = touches
            self.input.updateTouches(touches, deviceID: deviceID)
            if self.overlayDragging {
                self.recognizer.reset(waitForLift: !touches.isEmpty)
                self.centerFeedback.reset()
                self.calibrationGesture.reset(waitForLift: !touches.isEmpty)
                return
            }
            guard ProcessInfo.processInfo.systemUptime >= readyAt else {
                _ = self.recognizer.process(touches, at: timestamp, suppressInput: true)
                self.centerFeedback.reset(); self.calibrationGesture.reset(); return
            }
            if self.experimentalCalibration {
                let frame = self.calibrationGesture.process(touches, at: timestamp, allowFour: self.fourFingerCalibration, timing: self.calibrationTiming, reference: self.calibrationBaseline?.transform ?? self.calibrationTransform)
                if frame.consumed {
                    self.recognizer.reset(waitForLift: !touches.isEmpty)
                    self.centerFeedback.reset()
                    self.handleCalibration(frame)
                    return
                }
            }
            let logicalTouches = touches.map { self.effectiveTransform.apply($0) }
            let centerEvents = self.centerFeedback.processEvents(logicalTouches)
            if (self.hapticFiveEnter && centerEvents.contains(.entered)) ||
                (self.hapticFiveExit && centerEvents.contains(.exited)) {
                self.playHaptic(strong: true)
            }
            let confirmedKey = self.recognizer.process(logicalTouches, at: timestamp)
            if self.hapticTouchDown && self.recognizer.beganKey != nil { self.playHaptic() }
            if let key = confirmedKey {
                self.input.send(key)
                if self.hapticInputConfirmed { self.playHaptic() }
                self.lastKey = key.label
                self.showKeyHighlight(key.id)
                if self.sound { NSSound(named: "Tink")?.play() }
            }
        }
        guard stream?.start() == true else {
            stream = nil; input.stop(); messageText = LocalizedMessage(String(cString: TPError())); return
        }
        if !keepCalibrationOnReactivate {
            calibrationTransform = .identity
            hasCalibration = false
            calibrationText = LocalizedMessage("Using the default layout. Calibrate again if needed.")
            resetInputState()
        }
        enabled = true
        input.blocksSystemGestures = experimentalCalibration
        messageText = LocalizedMessage("Keypad active · Press Esc to exit")
        if NSApp.isActive {
            settingsWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            previousApp?.activate(options: [])
        }
        updateMenu(); updateGuide()
    }

    func disable() {
        saveDeviceSession()
        for (id, state) in deviceSessions where state.tracking && state.hasCalibration {
            if let data = try? JSONEncoder().encode(state.transform) { UserDefaults.standard.set(data, forKey: calibrationKey(for: id)) }
        }
        calibrationTracking = false; calibrationBaseline = nil
        enabled = false; generation += 1
        snapPanel?.orderOut(nil); overlaySnapPreview = nil; overlayDragging = false
        input.stop()
        stream?.stop(); stream = nil
        deviceSessions.removeAll()
        recognizer.reset(); centerFeedback.reset(); calibrationGesture.reset(); clearKeyHighlight(); touches = []
        previewRevision += 1
        activationInput = nil
        hideOverlay()
        messageText = LocalizedMessage("Keypad off. Use your trackpad as usual.")
        if item != nil { updateMenu() }
    }

    private func calibrationKey(for id: UInt64) -> String {
        let identity = trackpads.first { $0.id == id }?.persistentID ?? "unknown"
        let mapping = arrangement.codes.map(String.init).joined(separator: "-")
        return "calibration.devices.v2." + identity + "." + controlSide.rawValue + "." + mapping
    }
    private var calibrationKey: String { calibrationKey(for: currentDeviceID) }

    private func saveDeviceSession() {
        guard currentDeviceID != 0 else { return }
        deviceSessions[currentDeviceID] = DeviceSession(recognizer: recognizer, center: centerFeedback,
            gesture: calibrationGesture, touches: touches, transform: calibrationTransform,
            hasCalibration: hasCalibration, text: calibrationText, tracking: calibrationTracking, baseline: calibrationBaseline)
    }

    private func selectDeviceSession(_ id: UInt64) {
        guard id != currentDeviceID else { return }
        saveDeviceSession()
        currentDeviceID = id
        if let state = deviceSessions[id] {
            recognizer = state.recognizer; centerFeedback = state.center; calibrationGesture = state.gesture
            touches = state.touches; calibrationTransform = state.transform; hasCalibration = state.hasCalibration
            calibrationText = state.text; calibrationTracking = state.tracking; calibrationBaseline = state.baseline
        } else {
            touches = []
            configurationChanged()
        }
    }

    private func showKeyHighlight(_ keyID: UInt16) {
        // Each input owns its full highlight interval, including repeated keys.
        highlightClearWork?.cancel()
        highlighted = keyID
        let work = DispatchWorkItem { [weak self] in self?.clearKeyHighlight() }
        highlightClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func clearKeyHighlight() {
        highlightClearWork?.cancel()
        highlightClearWork = nil
        highlighted = nil
    }

    private func resetInputState() {
        calibrationTracking = false; calibrationBaseline = nil
        recognizer = AnchoredTapRecognizer(layout: controlSide, keys: keypadKeys)
        recognizer.reset(waitForLift: !touches.isEmpty)
        centerFeedback = CenterCrossingFeedback(layout: controlSide, keys: keypadKeys)
        calibrationGesture.reset(waitForLift: !touches.isEmpty)
        clearKeyHighlight()
    }

    private func configurationChanged() {
        let legacyKey = "calibration.similarity456.v1." + controlSide.rawValue
        if arrangement == KeyArrangement(), trackpads.first(where: { $0.id == currentDeviceID })?.builtIn == true,
           UserDefaults.standard.data(forKey: calibrationKey) == nil,
           let legacy = UserDefaults.standard.data(forKey: legacyKey) {
            UserDefaults.standard.set(legacy, forKey: calibrationKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        if let data = UserDefaults.standard.data(forKey: calibrationKey),
           let saved = try? JSONDecoder().decode(PadTransform.self, from: data), saved.isSimilarity {
            calibrationTransform = saved; hasCalibration = true
            calibrationText = LocalizedMessage("Saved calibration is ready.")
        } else {
            calibrationTransform = .identity; hasCalibration = false
            calibrationText = LocalizedMessage("No calibration yet.")
        }
        resetInputState()
    }

    private func persistCalibration() {
        guard hasCalibration, let data = try? JSONEncoder().encode(calibrationTransform) else { return }
        UserDefaults.standard.set(data, forKey: calibrationKey)
    }

    private func handleCalibration(_ frame: InteractiveCalibrationFrame) {
        guard let phase = frame.phase else { return }
        switch phase {
        case .began, .changed:
            if calibrationBaseline == nil {
                calibrationBaseline = (calibrationTransform, hasCalibration, calibrationText)
            }
            calibrationTracking = true
            if let points = frame.points {
                applyCalibration(points, persist: false, feedback: phase == .began, resetGesture: false, preserveOrder: true)
            }
        case .ended:
            if let points = frame.points {
                applyCalibration(points, persist: true, feedback: !calibrationTracking, resetGesture: false, preserveOrder: true)
            }
            calibrationTracking = false; calibrationBaseline = nil
        case .cancelled:
            if let baseline = calibrationBaseline {
                calibrationTransform = baseline.transform; hasCalibration = baseline.has; calibrationText = baseline.status
            }
            calibrationTracking = false; calibrationBaseline = nil
        }
    }

    private func applyCalibration(_ points: [PadPoint], persist: Bool = true, feedback: Bool = true,
                                  resetGesture: Bool = true, preserveOrder: Bool = false) {
        do {
            let transform = try PadTransform.calibrating(points, layout: controlSide, keys: keypadKeys, preserveOrder: preserveOrder, reference: calibrationBaseline?.transform ?? calibrationTransform)
            calibrationTransform = transform; hasCalibration = true
            if persist { persistCalibration() }
            calibrationText = LocalizedMessage(persist ? "%d-finger calibration applied · Position, rotation, and scale" : "Calibrating with %d fingers", count: points.count)
            if resetGesture { resetInputState() }
            if feedback && hapticCalibration { playHaptic() }
        } catch {
            calibrationText = LocalizedMessage(error.localizedDescription)
            if resetGesture { resetInputState() }
        }
    }

    func resetCalibration() {
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        configurationChanged()
    }

    func playHaptic(strong: Bool = false) {
        guard hapticsEnabled else { return }
        if currentDeviceID != 0 {
            _ = TPHapticForDevice(currentDeviceID, strong)
        } else if let id = selectedDeviceIDs.first {
            _ = TPHapticForDevice(id, strong)
        }
    }

    @objc func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func showSettings() {
        onboardingWindow?.close()
        if enabled { disable() }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = L("Numpad Settings")
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        refreshTrackpads()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showOnboarding() {
        if enabled { disable() }
        settingsWindow?.orderOut(nil)
        if onboardingWindow == nil {
            let model = OnboardingModel(app: self)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L("Welcome to Numpad")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0.045, green: 0.05, blue: 0.055, alpha: 1)
            window.contentView = NSHostingView(rootView: OnboardingView(model: model, app: self))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            model.onFinish = { [weak window] in window?.close() }
            model.onFocus = { [weak window] in
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            onboardingWindow = window
            onboarding = model
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func overlayScreen() -> NSScreen? {
        if enabled, let rect = activationInput?.field ?? activationInput?.caret {
            let best = NSScreen.screens.max { intersectionArea($0.frame, rect) < intersectionArea($1.frame, rect) }
            if let best, intersectionArea(best.frame, rect) > 0 { return best }
        }
        if let stored = UserDefaults.standard.dictionary(forKey: "overlayPosition"),
           let number = stored["screen"] as? NSNumber,
           let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == number }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private func preferredOverlayOrigin(screen: NSScreen, size: CGSize) -> CGPoint? {
        guard let stored = UserDefaults.standard.dictionary(forKey: "overlayPosition"),
              let x = stored["x"] as? Double, let y = stored["y"] as? Double, x.isFinite, y.isFinite else { return nil }
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        return CGPoint(x: bounds.minX + min(1, max(0, x)) * max(0, bounds.width - size.width),
                       y: bounds.minY + min(1, max(0, y)) * max(0, bounds.height - size.height))
    }

    private func updateGuide() {
        guard showGuide, let screen = overlayScreen() else { hideOverlay(); return }
        if panel == nil {
            let created = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.title = L("Numpad Overlay")
            created.contentView = NSHostingView(rootView: GuideView(model: self))
            created.isOpaque = false; created.backgroundColor = .clear
            created.hasShadow = true
            created.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            created.ignoresMouseEvents = false
            created.hidesOnDeactivate = false
            created.becomesKeyOnlyIfNeeded = true
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = created
        }
        guard let panel else { return }
        let size = OverlayPlacement.clamp(CGRect(origin: .zero, size: CGSize(width: 540, height: 360)), to: screen.visibleFrame).size
        let target = OverlayPlacement.place(size: size,
            preferredOrigin: preferredOverlayOrigin(screen: screen, size: size), on: screen.visibleFrame,
            avoiding: enabled ? activationInput?.field : nil, caret: enabled ? activationInput?.caret : nil)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        previewRevision += 1
        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: -6), display: true)
            panel.orderFrontRegardless()
        } else if !screen.visibleFrame.contains(panel.frame) {
            // Never animate through the gap between monitors or beyond a small display.
            panel.setFrame(target, display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        updateMirrorPanels(excluding: screen)
    }

    private func updateMirrorPanels(excluding primaryScreen: NSScreen) {
        let screens = showOnAllDisplays ? NSScreen.screens.filter {
            displayID(for: $0) != displayID(for: primaryScreen)
        } : []
        let activeIDs = Set(screens.map { displayID(for: $0) })
        for id in Array(mirrorPanels.keys) where !activeIDs.contains(id) {
            mirrorPanels[id]?.orderOut(nil)
            mirrorPanels.removeValue(forKey: id)
        }

        for screen in screens {
            let id = displayID(for: screen)
            let mirror: NSPanel
            if let existing = mirrorPanels[id] {
                mirror = existing
            } else {
                let created = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                created.title = L("Numpad Overlay")
                created.contentView = NSHostingView(rootView: GuideView(model: self))
                created.isOpaque = false; created.backgroundColor = .clear
                created.hasShadow = true
                created.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                created.ignoresMouseEvents = true
                created.hidesOnDeactivate = false
                created.becomesKeyOnlyIfNeeded = true
                created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                mirrorPanels[id] = created
                mirror = created
            }
            let size = OverlayPlacement.clamp(
                CGRect(origin: .zero, size: CGSize(width: 540, height: 360)), to: screen.visibleFrame).size
            let target = OverlayPlacement.place(size: size, preferredOrigin: nil,
                on: screen.visibleFrame, avoiding: nil, caret: nil)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !mirror.isVisible {
                mirror.alphaValue = reduceMotion ? 1 : 0
                mirror.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: -6), display: true)
                mirror.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                mirror.animator().setFrame(target, display: true)
                mirror.animator().alphaValue = 1
            }
        }
    }

    private func displayID(for screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func hideOverlay() {
        guard panel?.isVisible == true || mirrorPanels.values.contains(where: \.isVisible) else { return }
        let revision = previewRevision
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.10
        let visiblePanels = ([panel].compactMap { $0 } + Array(mirrorPanels.values)).filter(\.isVisible)
        for overlay in visiblePanels {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                overlay.animator().alphaValue = 0
            } completionHandler: { [weak self, weak overlay] in
                guard let self, let overlay,
                      (!self.enabled || !self.showGuide), self.previewRevision == revision else { return }
                overlay.orderOut(nil)
            }
        }
    }

    func beginOverlayDrag() {
        overlayDragging = true; previewRevision += 1
        recognizer.cancelCurrentTap()
        overlaySnapPreview = nil
    }

    func moveOverlay(to origin: CGPoint, pointer: CGPoint) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        if overlaySnapBounds != screen.visibleFrame { overlaySnapPreview = nil }
        let result = OverlaySnap.align(CGRect(origin: origin, size: panel.frame.size), on: screen.visibleFrame, previous: overlaySnapPreview)
        overlaySnapBounds = screen.visibleFrame
        overlaySnapPreview = result
        panel.setFrame(result.frame, display: true)
        if result.hasGuides {
            if snapPanel == nil {
                let guides = OverlayPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                guides.contentView = NSHostingView(rootView: SnapGuideView(model: self))
                guides.isOpaque = false; guides.backgroundColor = .clear
                guides.hasShadow = false; guides.ignoresMouseEvents = true; guides.hidesOnDeactivate = false
                guides.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
                guides.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                snapPanel = guides
            }
            snapPanel?.setFrame(screen.visibleFrame, display: true)
            snapPanel?.orderFrontRegardless()
        } else { snapPanel?.orderOut(nil) }
    }

    func endOverlayDrag() {
        overlayDragging = false; previewRevision += 1
        snapPanel?.orderOut(nil); overlaySnapPreview = nil
        if let panel, let screen = panel.screen ?? NSScreen.main {
            let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let frame = OverlayPlacement.clamp(panel.frame, to: screen.visibleFrame)
            panel.setFrame(frame, display: true)
            let x = (frame.minX - bounds.minX) / max(1, bounds.width - frame.width)
            let y = (frame.minY - bounds.minY) / max(1, bounds.height - frame.height)
            UserDefaults.standard.set(["x": Double(x), "y": Double(y),
                "screen": screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0], forKey: "overlayPosition")
        }
        if !enabled { schedulePreviewHide() }
    }

    func resetOverlayPosition() {
        UserDefaults.standard.removeObject(forKey: "overlayPosition")
        if panel?.isVisible == true {
            updateGuide()
            if !enabled { schedulePreviewHide() }
        }
    }

    private func schedulePreviewHide() {
        let revision = previewRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.enabled, !self.overlayDragging, self.previewRevision == revision else { return }
            self.hideOverlay()
        }
    }

    @objc func previewGuide() {
        updateGuide()
        schedulePreviewHide()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            // Dismissing the guide avoids showing it on every subsequent launch.
            OnboardingState.complete()
            onboarding?.tearDown()
            onboarding = nil
            onboardingWindow = nil
        }
        let other = window === settingsWindow ? onboardingWindow : settingsWindow
        if other?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }

    private func updateMenu() {
        item.button?.image = NSImage(systemSymbolName: enabled ? "rectangle.grid.3x3.fill" : "rectangle.grid.3x3", accessibilityDescription: "Numpad")
        item.button?.contentTintColor = enabled ? .systemMint : nil
        item.button?.toolTip = "Numpad · " + shortcutTitle
        let menu = NSMenu()
        menu.addItem(withTitle: (enabled ? L("Turn Keypad Off") : L("Turn Keypad On")) + "  " + shortcutTitle, action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L("Preview Keypad"), action: #selector(previewGuide), keyEquivalent: "")
        menu.addItem(withTitle: L("Getting Started…"), action: #selector(showOnboarding), keyEquivalent: "")
        if !trusted {
            menu.addItem(withTitle: L("Allow Accessibility Access…"), action: #selector(requestPermission), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Numpad"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingState.shouldPresent(arguments: []) {
            showOnboarding()
        } else {
            showSettings()
        }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        onboarding?.tearDown()
        disable(); TPHapticShutdown(); permissionTimer?.invalidate()
    }
}
