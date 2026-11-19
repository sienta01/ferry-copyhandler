import Combine
import FerryCore
import Foundation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let collision = "collisionPolicy"
        static let errors = "errorPolicy"
        static let verify = "verifyCopies"
        static let clones = "useClones"
        static let showWindow = "showWindowOnTransfer"
        static let percent = "showPercentInMenuBar"
        static let hideIcon = "hideMenuBarIconWhenIdle"
        static let notify = "notifyWhenDone"
        static let finderPaste = "handleFinderPaste"
    }

    private let defaults = UserDefaults.standard

    @Published var collision: CollisionPolicy { didSet { defaults.set(collision.rawValue, forKey: Key.collision) } }
    @Published var errors: ErrorPolicy { didSet { defaults.set(errors.rawValue, forKey: Key.errors) } }
    @Published var verify: Bool { didSet { defaults.set(verify, forKey: Key.verify) } }
    @Published var useClones: Bool { didSet { defaults.set(useClones, forKey: Key.clones) } }
    @Published var showWindowOnTransfer: Bool { didSet { defaults.set(showWindowOnTransfer, forKey: Key.showWindow) } }
    @Published var showPercentInMenuBar: Bool { didSet { defaults.set(showPercentInMenuBar, forKey: Key.percent) } }
    /// Only show the menu bar icon while something is queued or transferring.
    @Published var hideMenuBarIconWhenIdle: Bool { didSet { defaults.set(hideMenuBarIconWhenIdle, forKey: Key.hideIcon) } }
    @Published var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: Key.notify) } }
    @Published var handleFinderPaste: Bool { didSet { defaults.set(handleFinderPaste, forKey: Key.finderPaste) } }

    private init() {
        defaults.register(defaults: [
            Key.collision: CollisionPolicy.ask.rawValue,
            Key.errors: ErrorPolicy.ask.rawValue,
            Key.verify: false,
            Key.clones: true,
            Key.showWindow: true,
            Key.percent: true,
            Key.hideIcon: false,
            Key.notify: true,
            Key.finderPaste: false,
        ])
        collision = CollisionPolicy(rawValue: defaults.string(forKey: Key.collision) ?? "") ?? .ask
        errors = ErrorPolicy(rawValue: defaults.string(forKey: Key.errors) ?? "") ?? .ask
        verify = defaults.bool(forKey: Key.verify)
        useClones = defaults.bool(forKey: Key.clones)
        showWindowOnTransfer = defaults.bool(forKey: Key.showWindow)
        showPercentInMenuBar = defaults.bool(forKey: Key.percent)
        hideMenuBarIconWhenIdle = defaults.bool(forKey: Key.hideIcon)
        notifyWhenDone = defaults.bool(forKey: Key.notify)
        handleFinderPaste = defaults.bool(forKey: Key.finderPaste)
    }

    var transferOptions: TransferOptions {
        var o = TransferOptions()
        o.collision = collision
        o.errors = errors
        o.verify = verify
        o.useClones = useClones
        return o
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }
}
