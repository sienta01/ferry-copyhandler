import AppKit
import FinderSync

enum FinderBridge {
    static let finderBundleID = "com.apple.finder"

    /// The folder Finder would paste into right now (front window, column or Desktop).
    static func insertionLocation() -> URL? {
        let source = """
        tell application id "com.apple.finder" to return POSIX path of (insertion location as alias)
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let path = script.executeAndReturnError(&error).stringValue, !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    enum Permission { case granted, denied, notDetermined, unavailable }

    /// Automation permission for sending Apple events to Finder. With `ask`, macOS shows its prompt
    /// (this blocks, so call it off the main thread).
    static func automationPermission(ask: Bool) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: finderBundleID)
        guard let desc = target.aeDesc else { return .unavailable }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied        // errAEEventNotPermitted
        case -1744: return .notDetermined // errAEEventWouldRequireUserConsent
        default: return .unavailable
        }
    }

    static var extensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func openExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }

    static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
