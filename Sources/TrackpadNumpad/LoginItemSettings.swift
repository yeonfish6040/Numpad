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
    @StateObject private var service = LoginItemService()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Launch at Login"), isOn: Binding(
                get: { service.isRegistered }, set: { service.setEnabled($0) }))
                .toggleStyle(.switch).tint(mint)
                .disabled(!service.isPackagedApp)
            Text(L("Start Numpad in the menu bar when you log in. The keypad stays off until you activate it."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !service.isPackagedApp {
                Text(L("Open the installed Numpad app to configure launch at login."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if service.status == .requiresApproval {
                Text(L("Allow Numpad in System Settings → General → Login Items to finish enabling launch at login."))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = service.error {
                Text(L("Could not update launch at login.") + " " + error)
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
