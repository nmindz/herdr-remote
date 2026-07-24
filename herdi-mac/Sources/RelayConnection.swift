import Foundation
import Network
import Observation
import UserNotifications
import os.log

private let log = Logger(subsystem: "com.herdr.herdi", category: "Relay")

@Observable
final class RelayConnection {
    var agents: [Agent] = []
    var isConnected = false
    var hostAddress = RelayConnection.savedHostAddress() {
        didSet { UserDefaults.standard.set(hostAddress, forKey: "herdi_relay_host") }
    }
    var mode: ConnectionMode = .direct

    /// Relay URL precedence: what the user last saved, then HERDR_RELAY, then loopback.
    /// Accepts a bare host ("127.0.0.1:8375", "my-mac.ts.net") and fills in the scheme/port.
    static func savedHostAddress() -> String {
        let raw = UserDefaults.standard.string(forKey: "herdi_relay_host")
            ?? ProcessInfo.processInfo.environment["HERDR_RELAY"]
            ?? "ws://127.0.0.1:8375"
        return normalizeRelayURL(raw)
    }

    static func normalizeRelayURL(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "ws://127.0.0.1:8375" }
        if s.hasPrefix("http://") { s = "ws://" + s.dropFirst("http://".count) }
        else if s.hasPrefix("https://") { s = "wss://" + s.dropFirst("https://".count) }
        else if !s.hasPrefix("ws://") && !s.hasPrefix("wss://") { s = "ws://" + s }
        // Append the default port when the authority has none (ignoring any path).
        let schemeSplit = s.components(separatedBy: "://")
        if schemeSplit.count == 2 {
            let scheme = schemeSplit[0]
            var authority = schemeSplit[1]
            var path = ""
            if let slash = authority.firstIndex(of: "/") {
                path = String(authority[slash...])
                authority = String(authority[..<slash])
            }
            if !authority.contains(":") && scheme == "ws" {
                authority += ":8375"
            }
            s = "\(scheme)://\(authority)\(path)"
        }
        return s
    }

    enum ConnectionMode: String, CaseIterable {
        case direct = "Direct (herdr CLI)"
        case relay = "Relay (WebSocket)"
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pollTimer: Timer?
    private var reconnectAttempt = 0
    private var reconnecting = false
    private var handshakeWatchdog: Timer?
    var lastError: String?
    private let herdrPath: String
    var remotes: [String] = [] // SSH targets, e.g. ["user@host"]

    init() {
        herdrPath = ProcessInfo.processInfo.environment["HERDR_BIN"]
            ?? "/opt/homebrew/bin/herdr"
        // Load saved remotes
        if let saved = UserDefaults.standard.stringArray(forKey: "herdi_remotes") {
            remotes = saved
        }
        // Restore the mode the user last chose; previously the app always came back in Direct mode,
        // so a configured relay was silently ignored on every launch.
        let savedMode = UserDefaults.standard.string(forKey: "herdi_mode")
        log.info("Herdi starting — savedMode=\(savedMode ?? "nil", privacy: .public) host=\(self.hostAddress, privacy: .public)")
        if savedMode == ConnectionMode.relay.rawValue {
            connectRelay(to: hostAddress)
        } else {
            startDirect()
        }
    }

    // MARK: - Direct Mode (polls herdr CLI)

    func startDirect() {
        mode = .direct
        UserDefaults.standard.set(mode.rawValue, forKey: "herdi_mode")
        handshakeWatchdog?.invalidate()
        handshakeWatchdog = nil
        lastError = nil
        task?.cancel(with: .normalClosure, reason: nil)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollHerdr()
        }
        pollHerdr() // immediate first poll
    }

    private func pollHerdr() {
        DispatchQueue.global(qos: .utility).async { [self] in
            // Local
            var allAgents = parseAgents(from: runHerdr("pane", "list"), host: "local")

            // Remotes via SSH
            for remote in remotes {
                let result = runSSH(remote, "herdr", "pane", "list")
                allAgents += parseAgents(from: result, host: remote)
            }

            DispatchQueue.main.async { [self] in
                isConnected = true
                var seen = Set<String>()
                for a in allAgents {
                    seen.insert(a.id)
                    if let existing = agents.first(where: { $0.id == a.id }) {
                        if existing.status != a.status {
                            if a.status == .blocked && existing.status != .blocked {
                                readPaneForBlocked(existing, remote: a.host == "local" ? nil : a.host)
                            }
                            existing.status = a.status
                        }
                        if existing.project != a.project { existing.project = a.project }
                        if existing.host != a.host { existing.host = a.host }
                    } else {
                        let agent = Agent(id: a.id, name: a.name, status: a.status, project: a.project, cwd: a.cwd, host: a.host)
                        agents.append(agent)
                        if a.status == .blocked { readPaneForBlocked(agent, remote: a.host == "local" ? nil : a.host) }
                    }
                }
                agents.removeAll { !seen.contains($0.id) }
            }
        }
    }

    private struct ParsedAgent {
        let id: String, name: String, status: AgentStatus, project: String, cwd: String, host: String
    }

    private func parseAgents(from output: String, host: String) -> [ParsedAgent] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObj = json["result"] as? [String: Any],
              let panes = resultObj["panes"] as? [[String: Any]] else { return [] }

        return panes.compactMap { p in
            guard let agent = p["agent"] as? String, !agent.isEmpty else { return nil }
            let paneId = (host == "local" ? "" : "\(host):") + (p["pane_id"] as? String ?? "")
            let status = AgentStatus(rawValue: p["agent_status"] as? String ?? "unknown") ?? .unknown
            let cwd = p["cwd"] as? String ?? ""
            return ParsedAgent(id: paneId, name: agent, status: status, project: (cwd as NSString).lastPathComponent, cwd: cwd, host: host)
        }
    }

    private func runSSH(_ remote: String, _ args: String...) -> String {
        let process = Process()
        let password = KeychainHelper.getPassword(for: remote)

        if let password, FileManager.default.fileExists(atPath: "/opt/homebrew/bin/sshpass") {
            // Use sshpass for password auth
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
            process.arguments = ["-p", password, "ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", remote] + args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote] + args
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch { return "" }
    }

    func addRemote(_ remote: String, password: String? = nil) {
        guard !remote.isEmpty, !remotes.contains(remote) else { return }
        remotes.append(remote)
        UserDefaults.standard.set(remotes, forKey: "herdi_remotes")
        if let password, !password.isEmpty {
            KeychainHelper.setPassword(password, for: remote)
        }
    }

    func removeRemote(_ remote: String) {
        remotes.removeAll { $0 == remote }
        UserDefaults.standard.set(remotes, forKey: "herdi_remotes")
        KeychainHelper.deletePassword(for: remote)
    }

    private func readPaneForBlocked(_ agent: Agent, remote: String? = nil) {
        // Extract the real pane_id (strip host prefix if present)
        let paneId = agent.id.contains(":") && remote != nil
            ? String(agent.id.drop(while: { $0 != ":" }).dropFirst())
            : agent.id

        DispatchQueue.global(qos: .utility).async { [self] in
            let raw: String
            if let remote {
                raw = runSSH(remote, "herdr", "pane", "read", paneId, "--lines", "20", "--source", "recent")
            } else {
                raw = runHerdr("pane", "read", paneId, "--lines", "20", "--source", "recent")
            }
            let lines = raw.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(6)
            let content = lines.joined(separator: "\n")
            let options = detectOptions(content)

            DispatchQueue.main.async {
                agent.prompt = String(content.prefix(500))
                agent.options = options
                self.sendNotification(agent: agent.name, project: agent.project)
            }
        }
    }

    private func detectOptions(_ text: String) -> [String] {
        let lower = text.lowercased()
        if lower.contains("yes, single permission") {
            return ["yes, single permission", "trust, always allow", "no (tab to edit)"]
        }
        if lower.contains("approve all pending") {
            return ["approve all pending", "configure individually", "exit (cancel subagents)"]
        }
        return ["yes, single permission", "trust, always allow", "no (tab to edit)"]
    }

    private func runHerdr(_ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: herdrPath)
        process.arguments = Array(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Relay Mode (WebSocket)

    func connectRelay(to urlString: String) {
        let normalized = RelayConnection.normalizeRelayURL(urlString)
        guard let url = URL(string: normalized), url.host != nil else {
            lastError = "Invalid relay URL: \(urlString)"
            return
        }
        log.info("Connecting to relay \(normalized, privacy: .public)")
        mode = .relay
        UserDefaults.standard.set(mode.rawValue, forKey: "herdi_mode")
        hostAddress = normalized
        pollTimer?.invalidate()
        pollTimer = nil
        reconnecting = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = session.webSocketTask(with: url)
        task?.resume()
        // NOTE: reconnectAttempt is deliberately NOT reset here. This method is also the retry entry
        // point from scheduleReconnect(), so resetting it would flatten the backoff to a fixed ~2s and
        // hammer an unreachable relay forever. It resets in listen() once a message actually arrives.
        startHandshakeWatchdog(for: normalized)
        listen()
    }

    /// URLSessionWebSocketTask does not report an error when macOS blocks the connection — notably
    /// when Local Network privacy denies access to a LAN / Tailscale (100.64.0.0/10) address. The
    /// receive handler simply never fires, so the app looks connected-but-idle forever. Time it out
    /// and say what to check.
    private func startHandshakeWatchdog(for target: String) {
        handshakeWatchdog?.invalidate()
        let isLoopback = target.contains("127.0.0.1") || target.contains("localhost") || target.contains("[::1]")
        handshakeWatchdog = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self, !self.isConnected, self.mode == .relay else { return }
            self.lastError = isLoopback
                ? "No response from \(target) — is the relay running? (relay/start.sh)"
                : "No response from \(target). If the relay is running, grant Herdi access in System Settings ▸ Privacy & Security ▸ Local Network — macOS blocks LAN/Tailscale connections silently."
            log.error("Handshake watchdog fired for \(target, privacy: .public)")
            self.scheduleReconnect()
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        pollTimer?.invalidate()
        handshakeWatchdog?.invalidate()
        handshakeWatchdog = nil
        isConnected = false
    }

    func send(response: ResponseMessage) {
        if mode == .direct {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let paneId = response.pane_id
                // Check if this is a remote agent (id starts with "host:")
                if let agent = agents.first(where: { $0.id == paneId }), agent.host != "local" {
                    let realId = String(paneId.drop(while: { $0 != ":" }).dropFirst())
                    _ = runSSH(agent.host, "herdr", "pane", "send-text", realId, response.text + "\n")
                } else {
                    _ = runHerdr("pane", "send-text", paneId, response.text + "\n")
                }
            }
        } else {
            guard let data = try? JSONEncoder().encode(response) else { return }
            task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
        }
    }

    func focusPane(_ paneId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = runHerdr("pane", "focus", paneId)
        }
    }

    func interruptPane(_ paneId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = runHerdr("pane", "send-keys", paneId, "Ctrl+c")
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                DispatchQueue.main.async {
                    if !self.isConnected { self.isConnected = true }
                    self.reconnectAttempt = 0  // a real message proves the relay is healthy
                    self.lastError = nil
                    self.handshakeWatchdog?.invalidate()
                    self.handshakeWatchdog = nil
                }
                switch message {
                case .string(let text): self.handleWS(text)
                case .data(let data): self.handleWS(String(data: data, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.listen()
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.lastError = "\(self.hostAddress): \(error.localizedDescription)"
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !reconnecting, mode == .relay else { return }
        reconnecting = true
        reconnectAttempt += 1
        let delay = min(Double(1 << min(reconnectAttempt, 5)), 30.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isConnected else { return }
            self.reconnecting = false
            self.connectRelay(to: self.hostAddress)
        }
    }

    private func handleWS(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(AgentMessage.self, from: data) else { return }
        DispatchQueue.main.async { [self] in
            switch msg.type {
            case "agents":
                guard let list = msg.agents else { return }
                var seen = Set<String>()
                for a in list {
                    seen.insert(a.pane_id)
                    if let existing = agents.first(where: { $0.id == a.pane_id }) {
                        let s = AgentStatus(rawValue: a.status) ?? .unknown
                        if existing.status != s { existing.status = s }
                        if existing.project != a.project { existing.project = a.project }
                        existing.host = a.host ?? "local"
                    } else {
                        agents.append(Agent(
                            id: a.pane_id, name: a.agent,
                            status: AgentStatus(rawValue: a.status) ?? .unknown,
                            project: a.project, cwd: a.cwd, host: a.host ?? "local"
                        ))
                    }
                }
                agents.removeAll { !seen.contains($0.id) }
            case "blocked":
                if let pid = msg.pane_id, let agent = agents.first(where: { $0.id == pid }) {
                    agent.prompt = msg.prompt
                    agent.options = msg.options
                    agent.status = .blocked
                    sendNotification(agent: agent.name, project: agent.project)
                }
            default: break
            }
        }
    }

    private func sendNotification(agent: String, project: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Agent Blocked"
        content.body = "\(agent) needs input in \(project)"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
