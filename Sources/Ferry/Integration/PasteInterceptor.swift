import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FerryCore

/// Optional "make Ferry the paste handler for Finder" mode.
///
/// macOS has no public hook for replacing Finder's copy engine (Windows has shell copy hooks;
/// that's how TeraCopy does it). This is the closest equivalent: a keyboard event tap that, only
/// while Finder is frontmost, the clipboard holds files and no text field has focus, swallows ⌘V
/// (copy) / ⌥⌘V (move) and hands the paste to Ferry, using Finder's own idea of the current folder.
/// If anything is off (no files, Finder can't name a folder), the keystroke is replayed to Finder.
///
/// Needs Accessibility (to see and swallow the keystroke) and Automation → Finder (to ask for the
/// folder). Drag-and-drop between Finder windows still uses Finder's engine; there's no API for that.
final class PasteInterceptor {
    static let shared = PasteInterceptor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var wanted = false
    /// Tags events we replay so the tap lets them through.
    private static let replayMarker: Int64 = 0x4645_5252

    var isRunning: Bool { tap != nil }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func setEnabled(_ on: Bool) {
        wanted = on
        if on {
            start()
            DispatchQueue.global(qos: .userInitiated).async {
                if FinderBridge.automationPermission(ask: false) == .notDetermined {
                    _ = FinderBridge.automationPermission(ask: true)
                }
            }
        } else {
            stop()
        }
    }

    private func start() {
        guard wanted, tap == nil else { return }
        guard AXIsProcessTrusted() else {
            PasteInterceptor.requestAccessibility()
            waitForPermission()
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PasteInterceptor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            waitForPermission()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Starts the tap as soon as the user grants Accessibility in System Settings.
    private func waitForPermission() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.wanted { self.stop(); return }
            if AXIsProcessTrusted() {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.start()
            }
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != Self.replayMarker,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return pass }

        let flags = event.flags
        guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskShift) else { return pass }
        let key = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
        guard key == "v" || (key == nil && event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V)) else {
            return pass
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == FinderBridge.finderBundleID,
              Clipboard.hasFiles,
              !finderIsEditingText(front.processIdentifier) else { return pass }

        let move = flags.contains(.maskAlternate)
        let original = event.copy()
        DispatchQueue.main.async { self.paste(move: move, original: original) }
        return nil
    }

    private func paste(move: Bool, original: CGEvent?) {
        let files = Clipboard.fileURLs()
        guard !files.isEmpty, let destination = FinderBridge.insertionLocation() else {
            replay(original)
            return
        }
        AppController.shared.enqueue(move ? .move : .copy, sources: files, destination: destination)
    }

    private func replay(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cgSessionEventTap)
    }

    /// True while Finder is renaming a file or a search / Go to Folder field has focus,
    /// where ⌘V must paste text as usual.
    private func finderIsEditingText(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        return textRoles.contains(role as? String ?? "")
    }
}
