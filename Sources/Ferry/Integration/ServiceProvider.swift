import AppKit
import FerryCore

/// macOS Services, declared under NSServices in Info.plist. They show up in Finder's right-click
/// menu under Quick Actions / Services, which works even where Finder extensions don't load
/// (iCloud Drive, Dropbox and other File Provider folders).
final class ServiceProvider: NSObject {
    @objc(copyWithFerry:userData:error:)
    func copyWithFerry(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(pboard)
        DispatchQueue.main.async { AppController.shared.chooseDestination(for: urls, .copy) }
    }

    @objc(moveWithFerry:userData:error:)
    func moveWithFerry(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(pboard)
        DispatchQueue.main.async { AppController.shared.chooseDestination(for: urls, .move) }
    }

    /// "Paste with Ferry" on a selected folder: the clipboard's files go into that folder.
    @objc(pasteWithFerry:userData:error:)
    func pasteWithFerry(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let target = fileURLs(pboard).first else { return }
        var isDir: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) && isDir.boolValue
            ? target : target.deletingLastPathComponent()
        DispatchQueue.main.async { AppController.shared.pasteFromClipboard(into: folder, .copy) }
    }

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
