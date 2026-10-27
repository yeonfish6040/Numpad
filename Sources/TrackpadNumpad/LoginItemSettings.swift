import AppKit
import ServiceManagement
import SwiftUI

/// Read the system's actual state instead of a preference that could become
/// stale when the user changes Login Items in System Settings.
final class LoginItemService: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?
    let isPackagedApp = Bundle.main.bundleURL.pathExtension == "app"

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        guard isPackagedApp else { return }
        error = nil
        refresh()
        guard enabled != isRegistered else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

struct LoginItemSettings: View {
    @ObservedObject var model: AppController
    @StateObject private var service = LoginItemService()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("app.ui.launch_at_login"), isOn: Binding(
                get: { service.isRegistered }, set: { service.setEnabled($0) }))
                .toggleStyle(.switch).tint(mint)
                .disabled(!service.isPackagedApp)
            Text(L("app.ui.start_numpad_in_the_menu_bar_when_you_log_in_the_keypad_stays_off_until_you_activate_it"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !service.isPackagedApp {
                Text(L("app.ui.open_the_installed_numpad_app_to_configure_launch_at_login"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if service.status == .requiresApproval {
                Text(L("app.ui.allow_numpad_in_system_settings_general_login_items_to_finish_enabling_launch_at_login"))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("app.ui.open_login_items_settings")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = service.error {
                Text(L("app.ui.could_not_update_launch_at_login") + " " + error)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refresh()
        }
    }
}
