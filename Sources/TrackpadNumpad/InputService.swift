import AppKit
import ApplicationServices
import Carbon
import CTrackpad
import TrackpadCore

struct TrackpadDevice: Identifiable, Equatable {
    let id: UInt64
    let registryID: UInt64
    let persistentID: String
    let name: String
    let builtIn: Bool

    var displayName: String { name.hasPrefix("app.ui.") ? L(name) : name }

    static func connected(refresh: Bool = false) -> [Self] {
        if refresh { _ = TPRefreshDevices() }
        return (0..<TPDeviceCount()).compactMap { index in
            var info = TPDeviceInfo()
            guard TPGetDeviceInfo(index, &info) else { return nil }
            let name = withUnsafePointer(to: &info.name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
            let persistentID = withUnsafePointer(to: &info.persistentID) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            return Self(id: info.identifier, registryID: info.registryID, persistentID: persistentID,
                        name: name, builtIn: info.builtIn)
        }
    }
}

final class TouchStream {
    let receive: (UInt64, [Touch], Double) -> Void
    private let deviceIDs: [UInt64]
    private var revision = 0
    init(deviceIDs: [UInt64], receive: @escaping (UInt64, [Touch], Double) -> Void) {
        self.deviceIDs = deviceIDs; self.receive = receive
    }
    func start() -> Bool {
        revision += 1
        return TPStartDevices(deviceIDs, Int32(deviceIDs.count), { deviceID, pointer, count, timestamp, context in
            guard let context else { return }
            let stream = Unmanaged<TouchStream>.fromOpaque(context).takeUnretainedValue()
            let touches = (0..<Int(count)).compactMap { index -> Touch? in
                guard let item = pointer?[index] else { return nil }
                return Touch(id: item.identifier, x: Double(item.x), y: Double(item.y))
            }
            // Capture only copied framework data. Revision is checked on main,
            // never read on the framework thread.
            DispatchQueue.main.async { [weak stream] in
                guard let stream, stream.revision > 0 else { return }
                stream.receive(deviceID, touches, timestamp)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func stop() { TPStop(); revision = 0 }
}

final class InputService {
    private var earlyTap: CFMachPort?
    private var earlySource: CFRunLoopSource?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pointerFilter = DevicePointerFilter()
    private var senderCache: [UInt64: UInt64] = [:]
    var blocksClicks = true {
        didSet { pointerFilter.blocksClicks = blocksClicks }
    }
    var selectedDeviceIDs: Set<UInt64> = [] {
        didSet {
            senderCache.removeAll()
            pointerFilter = DevicePointerFilter(selected: selectedDeviceIDs, blocksClicks: blocksClicks)
        }
    }
    var blocksSystemGestures = false
    var onEscape: (() -> Void)?
    var onFailure: (() -> Void)?
    var onPhysicalClick: ((UInt64) -> Void)?

    func updateTouches(_ touches: [Touch], deviceID: UInt64) {
        guard selectedDeviceIDs.contains(deviceID) else { return }
        pointerFilter.updateTouches(deviceID: deviceID, count: touches.count, calibrationEnabled: blocksSystemGestures)
    }

    private func selectedSender(_ event: CGEvent) -> UInt64? {
        // Field 87 is the IORegistry sender ID, not the Multitouch device ID.
        // Unknown/synthetic events pass unchanged; no temporal attribution.
        let sender = UInt64(bitPattern: event.getIntegerValueField(CGEventField(rawValue: 87)!))
        guard sender != 0 else { return nil }
        let deviceID: UInt64
        if let cached = senderCache[sender] { deviceID = cached }
        else {
            deviceID = TPDeviceIDForSender(sender)
            if senderCache.count > 256 { senderCache.removeAll() }
            senderCache[sender] = deviceID
        }
        return DeviceInputPolicy(selected: selectedDeviceIDs).shouldFilter(deviceID: deviceID) ? deviceID : nil
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown]
        // Quartz does not expose names for these WindowServer gesture events.
        // 29: gesture envelope, 30: Dock control/magnification, 31: fluid swipe.
        // See https://github.com/oomol-lab/dockswipe for the Dock event pathway.
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            | SystemGestureFilter.eventMask
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Fail open: stop numpad instead of leaving input capture in a partial state.
                    service.onFailure?()
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                        service.onEscape?()
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard let deviceID = service.selectedSender(event) else { return Unmanaged.passUnretained(event) }
                let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                let kind: PointerEventKind
                switch type {
                case .mouseMoved: kind = .move
                case .scrollWheel: kind = .scroll
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down(button)
                case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up(button)
                case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .drag(button)
                default:
                    guard SystemGestureFilter.isGesture(type.rawValue) else { return Unmanaged.passUnretained(event) }
                    kind = .gesture
                }
                let allow = service.pointerFilter.allows(kind, deviceID: deviceID,
                    pressure: event.getDoubleValueField(.mouseEventPressure))
                if case .down = kind, event.getDoubleValueField(.mouseEventPressure) > 0 {
                    service.onPhysicalClick?(deviceID)
                }
                return allow ? Unmanaged.passUnretained(event) : nil
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port); return false
        }
        // Screen zoom can consume scroll/gesture packets before session taps.
        // Filter at the HID head as well, without moving ordinary key/click handling.
        let earlyMask = SystemGestureFilter.eventMask | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        guard let early = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: earlyMask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    service.onFailure?()
                    return Unmanaged.passUnretained(event)
                }
                return service.selectedSender(event) != nil ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let earlyRunSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, early, 0) else {
                CFMachPortInvalidate(port); return false
        }
        earlyTap = early; earlySource = earlyRunSource
        CFRunLoopAddSource(CFRunLoopGetMain(), earlyRunSource, .commonModes)
        CGEvent.tapEnable(tap: early, enable: true)
        tap = port; source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let earlyTap { CGEvent.tapEnable(tap: earlyTap, enable: false); CFMachPortInvalidate(earlyTap) }
        if let earlySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), earlySource, .commonModes) }
        earlyTap = nil; earlySource = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        senderCache.removeAll()
        pointerFilter = DevicePointerFilter(selected: selectedDeviceIDs, blocksClicks: blocksClicks)
        blocksSystemGestures = false
    }

    func send(_ key: PadKey) {
        let source = CGEventSource(stateID: .privateState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: isDown)
            event?.flags = key.keyCode == 51 ? [] : .maskNumericPad
            event?.post(tap: .cghidEventTap)
        }
    }
    deinit { stop() }
}

final class ActivationShortcut {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var chord = ModifierShortcutMatcher()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var started = false
    var action: (() -> Void)?
    var onProblem: ((String?) -> Void)?
    var suspended = false { didSet { chord.reset(); updateRegistration() } }
    var configuration = KeyboardShortcut.default { didSet { chord.reset(); updateRegistration() } }

    private func updateRegistration() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard started, !suspended else { return }
        guard let code = configuration.keyCode else { onProblem?(nil); return }
        if ShortcutAvailability.systemConflict(configuration) {
            onProblem?(L("app.ui.this_shortcut_is_assigned_in_macos_keyboard_shortcuts_choose_another_combination"))
            return
        }
        let result = RegisterEventHotKey(UInt32(code), ShortcutAvailability.carbonModifiers(configuration),
            EventHotKeyID(signature: 0x4E506164, id: 1), GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &hotKey)
        onProblem?(result == noErr ? nil : L("app.ui.this_shortcut_is_unavailable_or_registered_by_another_app_choose_another_combination") + " (\(result))")
    }

    func refreshAvailability() {
        guard started, !suspended, !configuration.isModifierOnly else { return }
        if hotKey == nil || ShortcutAvailability.systemConflict(configuration) { updateRegistration() }
    }

    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<ActivationShortcut>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                identifier.signature == 0x4E506164, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            if !shortcut.suspended { shortcut.action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let shortcut = Unmanaged<ActivationShortcut>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    shortcut.chord.reset()
                    if let tap = shortcut.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if !shortcut.suspended, shortcut.configuration.isModifierOnly,
                          shortcut.chord.update(flags: event.flags.rawValue, shortcut: shortcut.configuration) {
                    DispatchQueue.main.async { if !shortcut.suspended { shortcut.action?() } }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            if let handler { RemoveEventHandler(handler) }; handler = nil
            return
        }
        self.tap = port; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        started = true
        updateRegistration()
    }

    func stop() {
        started = false
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; chord.reset()
    }
    deinit { stop() }
}
