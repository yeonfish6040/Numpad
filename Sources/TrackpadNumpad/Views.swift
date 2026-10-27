import SwiftUI
import TrackpadCore
import Sparkle

private let ink = Color.white.opacity(0.9)

private struct TrackpadMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct KeypadView: View {
    var highlighted: UInt16?
    var compact = false
    var layout: KeypadLayout = .left
    var keys: [PadKey]?

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = compact ? 5 : 7
            let width = (geometry.size.width - gap * CGFloat(PadKey.columnCount - 1)) / CGFloat(PadKey.columnCount)
            let height = (geometry.size.height - gap * CGFloat(PadKey.rowCount - 1)) / CGFloat(PadKey.rowCount)
            ZStack(alignment: .topLeading) {
                ForEach(keys ?? layout.keys) { key in
                    let active = highlighted == key.id
                    let operation = key.isOperation
                    RoundedRectangle(cornerRadius: compact ? 7 : 10)
                        .fill(active ? mint : Color.white.opacity(operation ? 0.09 : 0.035))
                        .overlay {
                            RoundedRectangle(cornerRadius: compact ? 7 : 10)
                                .strokeBorder(active ? mint : Color.white.opacity(0.065), lineWidth: 1)
                        }
                        .overlay {
                            Text(key.label)
                                .font(.system(size: compact ? 17 : 23, weight: .medium, design: .rounded))
                                .foregroundStyle(active ? Color.black.opacity(0.85) : ink)
                        }
                        .frame(width: width * CGFloat(key.columns) + gap * CGFloat(key.columns - 1),
                               height: height * CGFloat(key.rows) + gap * CGFloat(key.rows - 1))
                        .offset(x: CGFloat(key.column) * (width + gap), y: CGFloat(key.row) * (height + gap))
                        .animation(active || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                            ? nil : .easeOut(duration: 0.08), value: active)
                        .accessibilityLabel(key.label)
                }
            }
        }
    }
}

struct GuideView: View {
    @ObservedObject var model: AppController
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    KeypadView(highlighted: model.highlighted, compact: true, layout: model.controlSide, keys: model.keypadKeys)
                        .transformEffect(model.effectiveTransform.inverse.screenTransform(size: geometry.size))
                        .animation(.easeOut(duration: (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || model.calibrationTracking) ? 0 : 0.18), value: model.effectiveTransform)
                    ForEach(Array(model.touches.enumerated()), id: \.offset) { _, touch in
                        Circle().fill(mint.opacity(0.25))
                            .overlay(Circle().strokeBorder(mint.opacity(0.8), lineWidth: 1))
                            .frame(width: 18, height: 18)
                            .position(x: min(1, max(0, touch.x)) * geometry.size.width,
                                      y: (1 - min(1, max(0, touch.y))) * geometry.size.height)
                    }
                }
                .clipped()
            }
            .aspectRatio(PadGeometry.aspectRatio, contentMode: .fit)
            .padding(14)
            .background {
                TrackpadMaterial()
                    .overlay(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            Text(L("app.ui.press_esc_to_exit"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        }
        .padding(8)
        .opacity(model.overlayOpacity)
        .overlay {
            OverlayDragSurface(began: { model.beginOverlayDrag() },
                moved: { model.moveOverlay(to: $0, pointer: $1) }, ended: { model.endOverlayDrag() })
        }
        .environment(\.colorScheme, .dark)
    }
}

private extension PadTransform {
    /// Convert bottom-left normalized coordinates to top-left view pixels.
    func screenTransform(size: CGSize) -> CGAffineTransform {
        guard size.width > 0, size.height > 0 else { return .identity }
        return CGAffineTransform(a: a, b: -c * size.height / size.width,
            c: -b * size.width / size.height, d: d,
            tx: size.width * (b + tx), ty: size.height * (1 - d - ty))
    }
}

struct SnapGuideView: View {
    @ObservedObject var model: AppController
    var body: some View {
        GeometryReader { geometry in
            if let snap = model.overlaySnapPreview {
                let bounds = model.overlaySnapBounds
                Path { path in
                    if let x = snap.verticalGuide {
                        let local = x - bounds.minX
                        path.move(to: CGPoint(x: local, y: 0))
                        path.addLine(to: CGPoint(x: local, y: geometry.size.height))
                    }
                    if let y = snap.horizontalGuide {
                        let local = bounds.maxY - y
                        path.move(to: CGPoint(x: 0, y: local))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: local))
                    }
                }.stroke(mint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(mint.opacity(0.35), lineWidth: 1)
                    .background(mint.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                    .frame(width: snap.frame.width, height: snap.frame.height)
                    .position(x: snap.frame.midX - bounds.minX, y: bounds.maxY - snap.frame.midY)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppController
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Numpad").font(.system(size: 23, weight: .semibold))
                Text(model.shortcutTitle + " · " + L("app.ui.press_esc_to_exit"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(model.message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TabView {
                generalSettings.tabItem { Text(L("app.ui.general")) }
                keyboardSettings.tabItem { Text(L("app.ui.keyboard")) }
                trackpadSettings.tabItem { Text(L("app.ui.trackpads")) }
                hapticSettings.tabItem { Text(L("app.ui.haptics")) }
                experimentalSettings.tabItem { Text(L("app.ui.experimental")) }
            }
            HStack {
                if !model.trusted {
                    Button(L("app.ui.allow_accessibility_access")) { model.requestPermission() }
                }
                Spacer()
                Button(L("app.ui.preview_overlay")) { model.previewGuide() }
            }
            Text(L("app.ui.changes_are_saved_automatically_opening_settings_turns_off_the_keypad"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 680, height: 740)
        .background(Color(red: 0.10, green: 0.105, blue: 0.11))
        .environment(\.colorScheme, .dark)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L("app.ui.language"))
                    Spacer()
                    Picker(L("app.ui.language"), selection: $model.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.name).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                Divider()
            LoginItemSettings(model: model)
            Divider()
            HStack {
                Text(L("app.ui.overlay_position")).font(.system(size: 12))
                Spacer()
                Button(L("app.ui.reset_to_bottom_center")) { model.resetOverlayPosition() }
            }
            Text(L("app.ui.click_and_drag_the_overlay_to_save_its_position_it_moves_out_of_the_way_when_it_would_cover_the_focused_input_field"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("app.ui.overlay_opacity")).font(.system(size: 12))
                    Spacer()
                    Text("\(Int(model.overlayOpacity * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.overlayOpacity, in: 0.1...1.0, step: 0.05).tint(mint)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("app.ui.show_overlay_on_all_displays"), isOn: $model.showOnAllDisplays)
                    .toggleStyle(.switch).tint(mint)
                Text(L("app.ui.when_enabled_the_overlay_appears_on_every_connected_display_only_the_primary_overlay_can_be_dragged"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("app.settings.block_physical_clicks"), isOn: $model.blocksClicks)
                    .toggleStyle(.switch).tint(mint)
                Text(L("app.settings.block_physical_clicks_help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            UpdatePreferences(updater: model.updater)
            Spacer(minLength: 0)
        }.padding(20)
    }

    private var keyboardSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShortcutSettings(model: model)
                Divider()
                KeyArrangementEditor(model: model)
            }.padding(20)
        }
    }

    private var trackpadSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L("app.ui.use_as_keypad")).font(.headline)
                    Spacer()
                    Button(L("app.ui.refresh_devices")) { model.refreshTrackpads() }
                }
                Text(L("app.ui.the_activation_shortcut_toggles_only_the_selected_trackpads_other_trackpads_keep_their_normal_pointer_clicks_scrolling_and_gestures"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if model.trackpads.isEmpty {
                    Label(L("app.ui.no_trackpad_found"), systemImage: "exclamationmark.triangle")
                }
                ForEach(model.trackpads) { device in
                    let receivingInput = model.activeInputDeviceIDs.contains(device.id)
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.and.hand.point.up.left").font(.title2).foregroundStyle(receivingInput ? Color.green : mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.displayName).fontWeight(.medium)
                            Text((device.builtIn ? L("app.ui.built_in") : L("app.ui.external")) + " · " + String(device.id, radix: 16).suffix(8))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(L("app.ui.use_as_keypad"), isOn: Binding(
                            get: { model.enabledTrackpads.contains(device.persistentID) },
                            set: { model.setTrackpad(device, enabled: $0) }))
                            .labelsHidden().toggleStyle(.switch).tint(mint)
                    }
                    .padding(14)
                    .background(receivingInput ? Color.green.opacity(0.14) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(receivingInput ? Color.green.opacity(0.8) : .white.opacity(0.08), lineWidth: receivingInput ? 1.5 : 1))
                    .animation(.easeInOut(duration: 0.12), value: receivingInput)
                }
                Text(L("app.ui.new_trackpads_stay_off_until_selected_a_connection_change_turns_the_keypad_off_safely_press_the_shortcut_to_resume_selection_is_remembered_for_recognized_devices"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(L("app.ui.events_whose_source_device_cannot_be_identified_pass_through_unchanged"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    private var hapticSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(L("app.ui.enable_haptics"), isOn: $model.hapticsEnabled)
                .font(.headline)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(L("app.ui.key_input")).font(.headline)
                Toggle(L("app.ui.on_touch_down"), isOn: $model.hapticTouchDown)
                Toggle(L("app.ui.when_a_tap_is_confirmed_on_release"), isOn: $model.hapticInputConfirmed)
                Divider()
                Text(L("app.ui.center_guide_for_5")).font(.headline)
                Toggle(L("app.ui.when_entering_the_center"), isOn: $model.hapticFiveEnter)
                Toggle(L("app.ui.when_leaving_the_center"), isOn: $model.hapticFiveExit)
                Text(L("app.ui.a_stronger_haptic_marks_the_small_center_region"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                Text(L("app.ui.experimental_calibration")).font(.headline)
                Toggle(L("app.ui.when_finger_calibration_is_applied"), isOn: $model.hapticCalibration)
            }
            .disabled(!model.hapticsEnabled)
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch).tint(mint)
        .padding(20)
    }

    private var experimentalSettings: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.trackpads.count > 1 {
                        Picker(L("app.ui.calibration_trackpad"), selection: Binding(
                            get: { model.currentDeviceID }, set: { model.selectCalibrationDevice($0) })) {
                            ForEach(model.trackpads) { device in
                                Text(device.displayName + " · " + String(device.id, radix: 16).suffix(8))
                                    .tag(device.id)
                            }
                        }
                    }
                    Toggle(isOn: $model.experimentalCalibration) {
                        HStack(spacing: 8) {
                            Text(L("app.ui.calibrate_with_finger_positions")).fontWeight(.medium)
                            Text(L("app.ui.experimental")).font(.system(size: 10)).foregroundStyle(mint)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(mint.opacity(0.1), in: Capsule())
                        }
                    }.toggleStyle(.switch).tint(mint)
                    Text(L("app.ui.with_the_keypad_on_place_three_fingers_together_keep_the_middle_finger_at_the_center_of_5_and_use_the_outer_fingers_to_adjust_rotation_and_scale_key_shapes_and_proportions_stay_the_same"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L("app.ui.apply_calibration"), selection: $model.calibrationTiming) {
                            Text(L("app.ui.on_touch")).tag(CalibrationTiming.touchDown)
                            Text(L("app.ui.on_release")).tag(CalibrationTiming.liftOff)
                        }.pickerStyle(.segmented)
                        Text(L("app.ui.defaults_to_on_touch_drag_with_three_or_four_fingers_to_move_rotate_and_scale_the_layout_live_only_events_identified_as_coming_from_selected_trackpads_are_blocked"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 12)
                    .disabled(!model.experimentalCalibration)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L("app.ui.keep_calibration_between_sessions"), isOn: $model.keepCalibrationOnReactivate)
                            .toggleStyle(.switch).tint(mint)
                        Text(L("app.ui.keep_the_last_calibration_when_turning_the_keypad_back_on_turn_this_off_to_start_each_session_with_the_default_layout_applies_to_the_next_session"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 12)
                    .disabled(!model.experimentalCalibration)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L("app.ui.enable_four_finger_calibration"), isOn: $model.fourFingerCalibration)
                            .toggleStyle(.switch).tint(mint)
                        Text(L("app.ui.place_four_fingers_together_the_middle_two_align_with_multiply_and_minus_from_left_to_right_adjusting_position_rotation_and_scale_to_match_their_key_centers"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(!model.experimentalCalibration)
                    Text(L("app.ui.calibration_is_saved_separately_for_each_trackpad_and_key_arrangement_turn_calibration_off_to_use_the_uncalibrated_layout"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        Text(model.calibrationStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("app.ui.reset_calibration")) { model.resetCalibration() }.disabled(!model.hasCalibration)
                    }
                }
                .padding(20)
        }
    }
}

private struct UpdatePreferences: View {
    let updater: SPUUpdater
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        _automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("app.ui.updates")).font(.system(size: 12, weight: .medium))
            Toggle(L("app.ui.automatically_check_for_updates"), isOn: $automaticallyChecksForUpdates)
                .toggleStyle(.switch).tint(mint)
                .onChange(of: automaticallyChecksForUpdates) { updater.automaticallyChecksForUpdates = $0 }
            Toggle(L("app.ui.automatically_install_updates"), isOn: $automaticallyDownloadsUpdates)
                .toggleStyle(.switch).tint(mint)
                .disabled(!automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)
                .onChange(of: automaticallyDownloadsUpdates) { updater.automaticallyDownloadsUpdates = $0 }
            Text(L("app.ui.update_settings_help"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
