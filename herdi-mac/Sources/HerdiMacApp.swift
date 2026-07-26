import SwiftUI
import ServiceManagement
import UserNotifications

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

        // Auto-expand when an agent gets blocked
        observeBlockedAgents()
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
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(relay: relay))
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
