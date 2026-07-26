import SwiftUI
import ServiceManagement

/// The status-bar dropdown: agent list, per-agent quick actions, and a real settings pane.
///
/// This is the app's primary surface. The notch panel is a separate, glanceable overlay — it does
/// not replace this, and the v0.6 rewrite dropping it left the status item with nothing but a plain
/// NSMenu.
struct MenuBarPanel: View {
    let relay: RelayConnection
    @State private var selectedAgent: Agent?
    @State private var showSettings = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    private let updater = Updater.shared

    private var localAgents: [Agent] { relay.agents.filter { $0.host == "local" } }
    private var remoteAgents: [Agent] { relay.agents.filter { $0.host != "local" } }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle().fill(relay.isConnected ? .green : .red).frame(width: 6, height: 6)
                Text("herdr").font(.headline)
                Spacer()
                Text("\(relay.agents.count) agents").font(.caption).foregroundStyle(.secondary)
                Button { showSettings.toggle() } label: {
                    Image(systemName: showSettings ? "list.bullet" : "gear").font(.caption)
                }
                .buttonStyle(.plain)
                .help(showSettings ? "Back to agents" : "Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            if showSettings {
                SettingsPanel(relay: relay, launchAtLogin: $launchAtLogin, updater: updater)
            } else if let agent = selectedAgent {
                ApprovalPanel(agent: agent, relay: relay) { selectedAgent = nil }
            } else {
                agentList
            }

            Divider()

            // Footer
            HStack(spacing: 8) {
                if let status = updater.status {
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if updater.updateAvailable {
                    Button("Update") { updater.performUpdate() }
                        .font(.caption).disabled(updater.isUpdating)
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { updater.checkForUpdates() }
        .onChange(of: launchAtLogin) { _, newValue in
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = !newValue  // registration failed — keep the toggle honest
            }
        }
    }

    private var agentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !localAgents.isEmpty {
                    hostSection("Local", agents: localAgents)
                }

                let remoteHosts = Set(remoteAgents.map(\.host)).sorted()
                ForEach(remoteHosts, id: \.self) { host in
                    hostSection("@\(host)", agents: remoteAgents.filter { $0.host == host })
                }

                // Configured remotes that reported nothing
                let connectedHosts = Set(remoteAgents.map(\.host))
                let disconnected = relay.remotes.filter { !connectedHosts.contains($0) }
                ForEach(disconnected, id: \.self) { remote in
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("@\(remote)").font(.caption).foregroundStyle(.secondary)
                        Text("— no agents / unreachable").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if relay.agents.isEmpty && relay.remotes.isEmpty {
                    VStack(spacing: 8) {
                        Text(relay.isConnected ? "No agents running" : "Connecting…")
                            .foregroundStyle(.secondary)
                        Text("Mode: \(relay.mode.rawValue)")
                            .font(.caption2).foregroundStyle(.tertiary)
                        if let err = relay.lastError {
                            Text(err).font(.caption2).foregroundStyle(.red)
                                .multilineTextAlignment(.center).padding(.horizontal, 20)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(12)
        }
    }

    private func hostSection(_ title: String, agents: [Agent]) -> some View {
        let blocked = agents.filter { $0.status == .blocked }
        let working = agents.filter { $0.status == .working }
        let idle = agents.filter { $0.status == .idle || $0.status == .unknown }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(agents.count)").font(.caption2).foregroundStyle(.tertiary)
            }

            if !blocked.isEmpty { statusGroup("Blocked", .red, blocked) }
            if !working.isEmpty { statusGroup("Working", .green, working) }
            if !idle.isEmpty { statusGroup("Idle", .gray, idle) }
        }
    }

    private func statusGroup(_ title: String, _ color: Color, _ agents: [Agent]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.leading, 8)
            ForEach(agents) { agent in
                AgentRow(agent: agent, relay: relay)
                    .onTapGesture {
                        if agent.status == .blocked { selectedAgent = agent }
                    }
            }
        }
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    let relay: RelayConnection
    @Binding var launchAtLogin: Bool
    let updater: Updater
    @State private var relayURL: String
    @State private var newRemote = ""
    @State private var newPassword = ""
    @AppStorage(NotchSettings.defaultsKey) private var notchPanelEnabled = true

    init(relay: RelayConnection, launchAtLogin: Binding<Bool>, updater: Updater) {
        self.relay = relay
        self._launchAtLogin = launchAtLogin
        self.updater = updater
        // Seed from the saved host rather than a hardcoded loopback, so the field shows what the
        // app will actually connect to.
        self._relayURL = State(initialValue: relay.hostAddress)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Mode").font(.caption)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { relay.mode },
                                set: { newMode in
                                    if newMode == .direct { relay.startDirect() }
                                    else { relay.connectRelay(to: relayURL) }
                                }
                            )) {
                                ForEach(RelayConnection.ConnectionMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }
                        HStack {
                            Text("Status").font(.caption)
                            Spacer()
                            Circle().fill(relay.isConnected ? .green : .red).frame(width: 6, height: 6)
                            Text(relay.isConnected ? "Connected" : "Disconnected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if relay.mode == .relay {
                            HStack {
                                TextField("ws://host:8375", text: $relayURL)
                                    .textFieldStyle(.roundedBorder).font(.caption)
                                    .onSubmit { relay.connectRelay(to: relayURL) }
                                Button("Connect") { relay.connectRelay(to: relayURL) }
                                    .font(.caption)
                            }
                            Text("A bare host works too — it fills in ws:// and :8375.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if relay.mode == .direct {
                            Text("Polling herdr CLI every 2s")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let err = relay.lastError, !relay.isConnected {
                            Text(err).font(.caption2).foregroundStyle(.red)
                        }
                    }
                    .padding(4)
                }

                GroupBox("Remote Hosts (SSH)") {
                    VStack(alignment: .leading, spacing: 8) {
                        if relay.remotes.isEmpty {
                            Text("No remotes configured").font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(relay.remotes, id: \.self) { remote in
                            HStack {
                                Image(systemName: "server.rack").font(.caption2)
                                Text(remote).font(.caption)
                                Spacer()
                                Button { relay.removeRemote(remote) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(remote)")
                            }
                        }
                        HStack {
                            TextField("user@host", text: $newRemote)
                                .textFieldStyle(.roundedBorder).font(.caption)
                            SecureField("password", text: $newPassword)
                                .textFieldStyle(.roundedBorder).font(.caption)
                                .frame(width: 80)
                            Button("Add") { addRemote() }
                                .font(.caption).disabled(newRemote.isEmpty)
                        }
                        Text("Password stored in Keychain. Leave blank for key auth.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(4)
                }

                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)
                            .toggleStyle(.switch).controlSize(.small)

                        Divider()

                        Toggle("Notch panel", isOn: $notchPanelEnabled)
                            .toggleStyle(.switch).controlSize(.small)
                        Text(notchPanelEnabled
                             ? "Overlay at the top of the screen. Hover it to see agents."
                             : "Off — this menu is the only interface. Turn on if you want the overlay back.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                GroupBox("Updates") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Current: v\(updater.currentVersion)").font(.caption)
                            Spacer()
                            if updater.updateAvailable {
                                Text("v\(updater.latestVersion ?? "?") available")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        HStack {
                            if updater.updateAvailable {
                                Button("Install Update") { updater.performUpdate() }
                                    .disabled(updater.isUpdating)
                            }
                            Spacer()
                            Button("Check Now") {
                                updater.lastCheck = nil
                                updater.checkForUpdates()
                            }
                            .font(.caption).disabled(updater.isChecking)
                        }
                        if let status = updater.status {
                            Text(status).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(12)
        }
    }

    private func addRemote() {
        relay.addRemote(newRemote.trimmingCharacters(in: .whitespaces),
                        password: newPassword.isEmpty ? nil : newPassword)
        newRemote = ""
        newPassword = ""
    }
}

// MARK: - Agent Row

struct AgentRow: View {
    let agent: Agent
    let relay: RelayConnection

    private var color: Color {
        switch agent.status {
        case .blocked: .red
        case .working: .green
        case .idle, .unknown: .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(agent.project.isEmpty ? "~" : agent.project)
                .font(.caption.monospaced()).lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(agent.name).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if agent.status == .blocked {
                Button {
                    relay.send(response: ResponseMessage(pane_id: agent.id, text: "yes, single permission"))
                } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .buttonStyle(.plain).help("Approve")
            }
            if agent.status == .working || agent.status == .blocked {
                Button { relay.interruptPane(agent.id) } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain).help("Interrupt (^C)")
            }
            Button { relay.jumpToAgent(agent) } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.blue.opacity(agent.canJump ? 1 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(!agent.canJump)
            .help(agent.canJump
                  ? "Open in terminal"
                  : (agent.host == "local" ? "Location not known yet" : "Agent is on \(agent.host)"))
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

// MARK: - Approval Panel

struct ApprovalPanel: View {
    let agent: Agent
    let relay: RelayConnection
    let onDismiss: () -> Void
    @State private var customResponse = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { onDismiss() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text("\(agent.name) — \(agent.project)").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)

            ScrollView {
                Text(agent.prompt ?? "Waiting…")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)

            if let options = agent.options {
                VStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button { respond(option) } label: {
                            Text(option).frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .tint(tint(for: option))
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack {
                TextField("Custom response…", text: $customResponse)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !customResponse.isEmpty { respond(customResponse) } }
                Button("Send") { respond(customResponse) }
                    .disabled(customResponse.isEmpty)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func respond(_ text: String) {
        relay.send(response: ResponseMessage(pane_id: agent.id, text: text))
        agent.status = .working
        agent.prompt = nil
        agent.options = nil
        onDismiss()
    }

    private func tint(for option: String) -> Color {
        if option.contains("yes") || option.contains("approve") { return .green }
        if option.contains("no") || option.contains("exit") || option.contains("cancel") { return .red }
        return .accentColor
    }
}
