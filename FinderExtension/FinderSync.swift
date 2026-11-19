import Cocoa
import FinderSync

/// Finder Sync extension: adds Ferry's items to Finder's right-click menu (and an optional toolbar
/// button). It's sandboxed and does no file work itself; it hands each request to Ferry.app
/// through an authenticated ferry:// URL (see IPCRequest.swift).
@objc(FinderSync)
final class FinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()

    override init() {
        super.init()
        // Menus on the startup disk. Finder doesn't extend this to other drives, and watching a
        // drive's root makes Finder show Ferry's icon for that drive in the sidebar, so external
        // drives are left to Services (right-click › Quick Actions / Services) and ⌘V takeover.
        controller.directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: Toolbar button (Finder ▸ View ▸ Customize Toolbar…)

    override var toolbarItemName: String { "Ferry" }
    override var toolbarItemToolTip: String { "Copy or move with Ferry" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Ferry") ?? NSImage()
    }

    // MARK: Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        let clipboardHasFiles = NSPasteboard.general.availableType(from: [.fileURL]) != nil

        switch menuKind {
        case .contextualMenuForItems:
            let selected = controller.selectedItemURLs() ?? []
            if clipboardHasFiles, selected.count == 1, isFolder(selected[0]) {
                add(to: menu, "Paste into Folder with Ferry", "doc.on.clipboard", #selector(pasteIntoSelection))
                add(to: menu, "Move into Folder with Ferry", "arrow.right.doc.on.clipboard", #selector(moveIntoSelection))
            }
            add(to: menu, "Copy To… with Ferry", "doc.on.doc", #selector(copyTo))
            add(to: menu, "Move To… with Ferry", "folder", #selector(moveTo))

        case .contextualMenuForContainer:
            guard clipboardHasFiles else { return nil }
            add(to: menu, "Paste with Ferry", "doc.on.clipboard", #selector(pasteHere))
            add(to: menu, "Move Here with Ferry", "arrow.right.doc.on.clipboard", #selector(moveHere))

        case .toolbarItemMenu:
            if clipboardHasFiles {
                add(to: menu, "Paste Here with Ferry", "doc.on.clipboard", #selector(pasteHere))
                add(to: menu, "Move Here with Ferry", "arrow.right.doc.on.clipboard", #selector(moveHere))
            }
            if !(controller.selectedItemURLs() ?? []).isEmpty {
                add(to: menu, "Copy Selection To…", "doc.on.doc", #selector(copyTo))
                add(to: menu, "Move Selection To…", "folder", #selector(moveTo))
            }
            add(to: menu, "Show Ferry", "list.bullet", #selector(showApp))

        default:
            return nil
        }
        return menu
    }

    private func add(to menu: NSMenu, _ title: String, _ symbol: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func isFolder(_ url: URL) -> Bool {
        if let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           let dir = isDir.isDirectory {
            return dir && isDir.isPackage != true
        }
        return url.hasDirectoryPath
    }

    // MARK: Actions (Finder calls these on the extension's principal object)

    @objc func pasteHere(_ sender: AnyObject?) {
        send(IPCRequest(action: "paste", destination: controller.targetedURL()?.path))
    }

    @objc func moveHere(_ sender: AnyObject?) {
        send(IPCRequest(action: "paste", move: true, destination: controller.targetedURL()?.path))
    }

    @objc func pasteIntoSelection(_ sender: AnyObject?) {
        send(IPCRequest(action: "paste", destination: controller.selectedItemURLs()?.first?.path))
    }

    @objc func moveIntoSelection(_ sender: AnyObject?) {
        send(IPCRequest(action: "paste", move: true, destination: controller.selectedItemURLs()?.first?.path))
    }

    @objc func copyTo(_ sender: AnyObject?) {
        send(IPCRequest(action: "copyto", sources: (controller.selectedItemURLs() ?? []).map(\.path)))
    }

    @objc func moveTo(_ sender: AnyObject?) {
        send(IPCRequest(action: "moveto", sources: (controller.selectedItemURLs() ?? []).map(\.path)))
    }

    @objc func showApp(_ sender: AnyObject?) {
        if let url = URL(string: "ferry://show") { NSWorkspace.shared.open(url) }
    }

    private func send(_ request: IPCRequest) {
        guard let url = request.url else { return }
        NSWorkspace.shared.open(url)
    }
}
