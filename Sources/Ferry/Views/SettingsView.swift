import Combine
import FerryCore
import SwiftUI

/// Finder-extension, permission and login-item state shown in Settings and the empty window.
final class SystemStatus: ObservableObject {
    static let shared = SystemStatus()

    @Published private(set) var extensionEnabled = FinderBridge.extensionEnabled
    @Published private(set) var accessibility = PasteInterceptor.hasAccessibility
    @Published private(set) var automation = FinderBridge.Permission.unavailable
    @Published private(set) var launchAtLogin = Settings.shared.launchAtLogin
    @Published private(set) var loginError: String?

    func refresh(includingAutomation: Bool = false) {
        update(\.extensionEnabled, FinderBridge.extensionEnabled)
        update(\.accessibility, PasteInterceptor.hasAccessibility)
        update(\.launchAtLogin, Settings.shared.launchAtLogin)
        guard includingAutomation else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = FinderBridge.automationPermission(ask: false)
            DispatchQueue.main.async { self.update(\.automation, result) }
        }
    }

    func requestAutomation() {
        if automation == .denied {
            FinderBridge.openPrivacySettings("Privacy_Automation")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FinderBridge.automationPermission(ask: true)
            DispatchQueue.main.async { self.update(\.automation, result) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try Settings.shared.setLaunchAtLogin(on)
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        update(\.launchAtLogin, Settings.shared.launchAtLogin)
    }

    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<SystemStatus, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var status = SystemStatus.shared
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Transfers") {
                Picker("When an item already exists", selection: $settings.collision) {
                    ForEach(CollisionPolicy.allCases) { Text($0.title).tag($0) }
                }
                Picker("When a file can't be copied", selection: $settings.errors) {
                    ForEach(ErrorPolicy.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.verify) {
                    Text("Verify copies")
                    Text("Re-reads each copy and compares SHA-256 checksums with the original. Slower.")
                }
                Toggle(isOn: $settings.useClones) {
                    Text("Use APFS clones on the same disk")
                    Text("Copies within one APFS disk finish instantly and take no extra space, like Finder's.")
                }
            }

            Section("Finder") {
                LabeledContent {
                    if status.extensionEnabled {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Turn On…") { FinderBridge.openExtensionSettings() }
                    }
                } label: {
                    Text("Right-click menu")
                    Text("“Paste with Ferry”, “Move Here with Ferry”, “Copy To…” and “Move To…” in Finder.")
                }
                Toggle(isOn: $settings.handleFinderPaste) {
                    Text("Handle ⌘V and ⌥⌘V in Finder")
                    Text("Files you copy with ⌘C and paste with ⌘V (or move with ⌥⌘V) in Finder go through Ferry instead of Finder. Renaming and other text fields are left alone.")
                }
                if settings.handleFinderPaste {
                    permissionRow("Accessibility", granted: status.accessibility,
                                  detail: "Lets Ferry see ⌘V while Finder is in front.") {
                        PasteInterceptor.requestAccessibility()
                        FinderBridge.openPrivacySettings("Privacy_Accessibility")
                    }
                    permissionRow("Automation → Finder", granted: status.automation == .granted,
                                  detail: "Lets Ferry ask Finder which folder you're pasting into.") {
                        status.requestAutomation()
                    }
                }
            }

            Section("Ferry") {
                Toggle("Show the transfer window when a transfer starts", isOn: $settings.showWindowOnTransfer)
                Toggle("Show the percentage in the menu bar", isOn: $settings.showPercentInMenuBar)
                Toggle(isOn: $settings.hideMenuBarIconWhenIdle) {
                    Text("Hide the menu bar icon when not in use")
                    Text("The icon appears only while something is copying or moving. Ferry keeps running; open it from Spotlight, Launchpad or the Applications folder to see the window.")
                }
                Toggle("Notify me when a transfer finishes", isOn: $settings.notifyWhenDone)
                Toggle("Open at login", isOn: Binding(get: { status.launchAtLogin }, set: { status.setLaunchAtLogin($0) }))
                if let error = status.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { status.refresh(includingAutomation: settings.handleFinderPaste) }
        .onReceive(poll) { _ in status.refresh(includingAutomation: settings.handleFinderPaste) }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
