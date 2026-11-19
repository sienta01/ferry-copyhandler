import AppKit
import FerryCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedInBackground = false
    private let services = ServiceProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Opened at login: stay in the menu bar. Opened by the user: show the transfer list.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedInBackground = true
        }
        if CommandLine.arguments.contains("--background") { launchedInBackground = true }
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        AppController.shared.start(showWindow: !launchedInBackground && !DevSnapshot.isActive)
        if DevSnapshot.isActive { DevSnapshot.run() }
    }

    /// Double-clicking Ferry (Finder, Spotlight, Launchpad) while it's running opens the transfer list.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.showTransfers(activate: true)
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppController.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppController.shared.applicationShouldTerminate()
    }
}

/// The menu bar shown while a Ferry window is open (and the Dock icon is visible).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let actions = MenuActions.shared

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ferry", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(MenuActions.settings), ",", target: actions))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ferry", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ferry", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: "Ferry", to: main)

        let file = NSMenu(title: "File")
        file.addItem(item("Copy Files To…", #selector(MenuActions.copyFiles), "n", target: actions))
        let move = item("Move Files To…", #selector(MenuActions.moveFiles), "n", target: actions)
        move.keyEquivalentModifierMask = [.command, .option]
        file.addItem(move)
        let paste = item("Paste Copied Files Into…", #selector(MenuActions.pasteFiles), "v", target: actions)
        paste.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(paste)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(item("Transfers", #selector(MenuActions.transfers), "0", target: actions))
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ submenu: NSMenu, titled title: String, to main: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        main.addItem(holder)
    }

    static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

/// Selector targets shared by the main menu and the menu bar menu.
final class MenuActions: NSObject {
    static let shared = MenuActions()
    private var app: AppController { .shared }

    @objc func transfers() { app.showTransfers(activate: true) }
    @objc func settings() { app.showSettings() }
    @objc func copyFiles() { app.chooseSourcesAndTransfer(.copy) }
    @objc func moveFiles() { app.chooseSourcesAndTransfer(.move) }
    @objc func pasteFiles() { app.pasteFromClipboard(into: nil, .copy) }
    @objc func pauseAll() { app.queue.pauseAll() }
    @objc func resumeAll() { app.queue.resumeAll() }
    @objc func cancelAll() { app.queue.cancelAll() }
    @objc func quit() { NSApp.terminate(nil) }
}
