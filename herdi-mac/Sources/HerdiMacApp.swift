import SwiftUI
import ServiceManagement
import UserNotifications
import os.log

private let log = Logger(subsystem: "com.herdr.herdi", category: "App")

@main
struct HerdiApp: App {
    @NSApplicationDelegateAdaptor(HerdiAppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible window — the panel IS the UI
        Settings { EmptyView() }
    }
}

@MainActor
class HerdiAppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelWindowController?
    let relay = RelayConnection()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appliedNotchEnabled = true
    private var observingNotchSetting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Minimal status bar item (quit + show panel)
        setupStatusItem()

        // The notch overlay is optional — the status-bar dropdown is the app on its own.
        panelController = PanelWindowController(relay: relay)
        if NotchSettings.panelEnabled {
            panelController?.showPanel()
        }
        observeNotchSetting()
        syncLaunchAtLogin()

        // Auto-expand when an agent gets blocked
        observeBlockedAgents()
    }

    /// Reconcile the stored preference with the actual login-item registration.
    ///
    /// The two can disagree: register()/unregister() can throw, and the old toggle discarded that
    /// error so the switch showed a state the system never had. The preference can also be changed
    /// while the app is not running. Settle it at startup so the toggle never lies.
    private func syncLaunchAtLogin() {
        let wanted = UserDefaults.standard.bool(forKey: "launchAtLogin")
        guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login \(wanted ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        // register() can return without throwing and still not take effect: an ad-hoc-signed app's
        // login item sits in .requiresApproval until the user approves it under System Settings ▸
        // General ▸ Login Items. Trusting the non-throw left the toggle showing "on" while the
        // system had it unregistered, so verify the resulting status instead of the call.
        let actual = SMAppService.mainApp.status
        let achieved = actual == .enabled
        guard achieved != wanted else {
            log.info("Launch at login now \(achieved, privacy: .public)")
            return
        }
        UserDefaults.standard.set(achieved, forKey: "launchAtLogin")
        log.error("""
            Launch at login could not be set to \(wanted, privacy: .public) \
            (status=\(Self.describe(actual), privacy: .public)) — preference corrected to \
            \(achieved, privacy: .public)
            """)
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown(\(status.rawValue))"
        }
    }

    /// Apply the notch preference live.
    ///
    /// KVO on the key, not `UserDefaults.didChangeNotification` — that notification only fires for
    /// writes made inside this process, so the setting would silently not apply when changed by any
    /// other route. KVO observes both, which also keeps UserDefaults the single source of truth
    /// instead of adding a bespoke notification just for the toggle.
    private func observeNotchSetting() {
        appliedNotchEnabled = NotchSettings.panelEnabled
        UserDefaults.standard.addObserver(
            self, forKeyPath: NotchSettings.defaultsKey, options: [.new], context: nil
        )
        observingNotchSetting = true
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == NotchSettings.defaultsKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        Task { @MainActor in
            let enabled = NotchSettings.panelEnabled
            guard enabled != self.appliedNotchEnabled else { return }
            self.appliedNotchEnabled = enabled
            self.panelController?.setEnabled(enabled)
        }
    }

    deinit {
        // removeObserver throws if it was never added.
        if observingNotchSetting {
            UserDefaults.standard.removeObserver(self, forKeyPath: NotchSettings.defaultsKey)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Herdi")
            button.image?.size = NSSize(width: 14, height: 14)
            // A popover, not `statusItem.menu` — the dropdown is a full SwiftUI surface (agent list,
            // approvals, settings), which an NSMenu cannot host.
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // LSUIElement apps are not active, so text fields in the popover would not accept focus
        // until something makes its window key.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.contentViewController = PopoverHostingController(
            rootView: MenuBarPanel(relay: relay),
            size: NSSize(width: 360, height: 480)
        )
        return popover
    }

    /// Watch for agents transitioning to blocked state and auto-expand the panel
    private func observeBlockedAgents() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let blocked = self.relay.agents.filter { $0.status == .blocked }

                // Update status item icon
                if let button = self.statusItem?.button {
                    if !blocked.isEmpty {
                        button.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Blocked")
                        button.image?.size = NSSize(width: 16, height: 16)
                        button.contentTintColor = .systemRed
                    } else {
                        button.image = NSImage(systemSymbolName: self.relay.isConnected ? "circle.fill" : "circle", accessibilityDescription: "Herdi")
                        button.image?.size = NSSize(width: 14, height: 14)
                        button.contentTintColor = nil
                    }
                }

                // Auto-pop the approval card if panel is collapsed and there's a blocked agent.
                // Skipped when the overlay is off, or a blocked agent would pop it back on screen.
                if NotchSettings.panelEnabled,
                   let agent = blocked.first, self.panelController?.surface == .collapsed {
                    withAnimation(NotchAnimation.pop) {
                        self.panelController?.surface = .approval(agentId: agent.id)
                    }
                }
            }
        }
    }
}

// MARK: - Popover hosting

/// NSHostingView that actuates on the FIRST click.
///
/// Herdi is an LSUIElement app, so it is never the active application and its popover window is not
/// key. AppKit then spends the first click activating the window instead of delivering it, which
/// means every button in the dropdown needs clicking twice — the gear, Approve, Interrupt, the jump
/// arrow. NotchHostingView already does this for the notch overlay; the popover needs the same.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

private final class PopoverHostingController<Content: View>: NSViewController {
    private let root: Content
    private let size: NSSize

    init(rootView: Content, size: NSSize) {
        self.root = rootView
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        view = hosting
    }
}
