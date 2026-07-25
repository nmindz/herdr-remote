import Foundation
import AppKit
import Observation
import os.log

private let log = Logger(subsystem: "com.herdr.herdi", category: "Updater")

/// "Check for updates" against a GitHub repository's releases.
///
/// Two strategies, in order:
///  - **HTTP** — unauthenticated GET on the public releases REST endpoint. Dependency-free, and the
///    only path that works on a machine without the `gh` CLI.
///  - **gh CLI** — shells out to the host's `gh`, reusing the user's existing GitHub auth. Required
///    when the repo is PRIVATE: the unauthenticated endpoint returns 404 for private repos, which is
///    indistinguishable from "no releases published yet".
///
/// Set `HERDI_UPDATE_REPO=owner/name` to point the check at a different repository (a fork, say)
/// without rebuilding.
@Observable
final class Updater {
    static let shared = Updater()

    /// Read from the bundle so it tracks the Makefile's VERSION instead of being a second copy that
    /// drifts. Falls back only when running the bare binary outside a .app.
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0-dev"

    let repo = ProcessInfo.processInfo.environment["HERDI_UPDATE_REPO"] ?? "nmindz/herdr-remote"

    var latestVersion: String?
    var updateAvailable = false
    var isChecking = false
    var isUpdating = false
    var status: String?

    private var downloadURL: URL?
    var lastCheck: Date?

    func checkForUpdates() {
        if let last = lastCheck, Date().timeIntervalSince(last) < 600 { return }
        guard !isChecking else { return }
        isChecking = true
        status = "Checking…"
        lastCheck = Date()

        Task {
            defer { DispatchQueue.main.async { self.isChecking = false } }

            switch await latestRelease() {
            case .success(let json):
                DispatchQueue.main.async { self.handleRelease(json) }
            case .noReleases:
                // A fork with no published releases is the normal state, not a failure — saying
                // "check failed" here would nag about a problem the user does not have.
                log.info("No releases published for \(self.repo, privacy: .public)")
                DispatchQueue.main.async {
                    self.updateAvailable = false
                    self.latestVersion = nil
                    self.status = "v\(self.currentVersion) (no releases)"
                }
            case .failure(let reason):
                log.error("Update check failed: \(reason, privacy: .public)")
                DispatchQueue.main.async { self.status = "v\(self.currentVersion) (check failed)" }
            }
        }
    }

    private enum ReleaseResult {
        case success([String: Any])
        case noReleases
        case failure(String)
    }

    private func latestRelease() async -> ReleaseResult {
        let http = await httpRelease()
        if case .success = http { return http }
        // 404 means either private or no releases. `gh` can tell the difference, so try it before
        // concluding anything — but only when it is actually installed.
        if case .noReleases = http, Updater.ghPath == nil { return http }

        switch await ghRelease() {
        case .success(let json): return .success(json)
        case .noReleases: return .noReleases
        case .failure(let ghReason):
            if case .noReleases = http { return .noReleases }
            return .failure(ghReason)
        }
    }

    // MARK: - HTTP strategy

    private func httpRelease() async -> ReleaseResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failure("bad repo string: \(repo)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub's REST API rejects requests without a User-Agent.
        request.setValue("herdi-update-check/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        // Use a token if the environment already has one; lets the HTTP path work for private repos
        // and lifts the 60/hr unauthenticated rate limit.
        let env = ProcessInfo.processInfo.environment
        if let token = env["GH_TOKEN"] ?? env["GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("no HTTP response") }
            if http.statusCode == 404 { return .noReleases }
            guard http.statusCode == 200 else { return .failure("HTTP \(http.statusCode)") }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("unparseable GitHub response")
            }
            return .success(json)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - gh CLI strategy

    /// Located once per process. A packaged .app launches without a shell profile (launchd gives it
    /// a minimal PATH), so scanning PATH alone misses both Homebrew and version-manager installs —
    /// a `gh` under mise/asdf is invisible to the app otherwise.
    private static let ghPath: String? = discoverGh()

    private static func discoverGh() -> String? {
        let fm = FileManager.default

        // 1. PATH — covers dev runs and any GUI session with a usable PATH.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/gh"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        // 2. The user's LOGIN shell, which sources their profile — this is what resolves mise/asdf
        //    shims and custom PATH setups. ~40ms, and only on an explicit update check.
        if let found = loginShellWhich("gh") { return found }

        // 3. Well-known locations, as a last resort.
        let home = fm.homeDirectoryForCurrentUser.path
        let known = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
            "/home/linuxbrew/.linuxbrew/bin/gh",
            "\(home)/.local/share/mise/shims/gh",
            "\(home)/.asdf/shims/gh",
            "\(home)/.local/bin/gh",
        ]
        return known.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func loginShellWhich(_ exe: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(exe)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        } catch {
            return nil
        }
    }

    private func ghRelease() async -> ReleaseResult {
        guard let gh = Updater.ghPath else { return .failure("GitHub CLI (gh) not found") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gh)
                process.arguments = ["api", "repos/\(self.repo)/releases/latest"]
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure("failed to run gh: \(error.localizedDescription)"))
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    // gh reports a missing release as an HTTP 404 on stderr.
                    if stderr.contains("404") || stderr.contains("Not Found") {
                        continuation.resume(returning: .noReleases)
                    } else {
                        continuation.resume(returning: .failure("gh api failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
                    }
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: .failure("unparseable gh response"))
                    return
                }
                continuation.resume(returning: .success(json))
            }
        }
    }

    // MARK: - Release handling

    /// `v0.2.1` → `0.2.1`. Release tags carry a `v`; CFBundleShortVersionString does not.
    static func normalizeTag(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = t.first, first == "v" || first == "V" { t.removeFirst() }
        return t
    }

    private func handleRelease(_ json: [String: Any]) {
        guard let tag = json["tag_name"] as? String else {
            status = "v\(currentVersion)"
            return
        }
        let version = Updater.normalizeTag(tag)
        guard !version.isEmpty else {
            status = "v\(currentVersion)"
            return
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmgAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let dmgURL = dmgAsset?["browser_download_url"] as? String

        latestVersion = version
        downloadURL = dmgURL.flatMap { URL(string: $0) }
        // Only offer an update when the published release is actually NEWER. A plain `!=` also fires
        // when running a local build ahead of the last release, which nags with a downgrade.
        updateAvailable = Updater.isNewer(version, than: currentVersion) && downloadURL != nil
        status = updateAvailable ? "v\(version) available" : "v\(currentVersion) ✓"
    }

    /// Numeric semver-ish comparison. `10.0.0 > 9.0.0`, which a string compare gets wrong.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
                .prefix(3)
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func performUpdate() {
        guard let url = downloadURL, !isUpdating else { return }
        isUpdating = true
        status = "Downloading…"

        Task {
            do {
                // Download DMG via public URL
                let dmgPath = FileManager.default.temporaryDirectory.appendingPathComponent("Herdi-update.dmg")
                try? FileManager.default.removeItem(at: dmgPath)
                let (fileURL, _) = try await URLSession.shared.download(from: url)
                try FileManager.default.moveItem(at: fileURL, to: dmgPath)

                DispatchQueue.main.async { self.status = "Installing…" }

                let appDest = Bundle.main.bundlePath

                // Write a script that runs AFTER this app quits
                let script = """
                #!/bin/bash
                sleep 1
                hdiutil attach "\(dmgPath.path)" -nobrowse -quiet
                if [ -d "/Volumes/Herdi/Herdi.app" ]; then
                    rm -rf "\(appDest)"
                    cp -R "/Volumes/Herdi/Herdi.app" "\(appDest)"
                    hdiutil detach "/Volumes/Herdi" -quiet
                    rm -f "\(dmgPath.path)"
                    open "\(appDest)"
                else
                    hdiutil detach "/Volumes/Herdi" -quiet 2>/dev/null
                fi
                rm -f /tmp/herdi-update.sh
                """

                let scriptPath = "/tmp/herdi-update.sh"
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                chmod(scriptPath, 0o755)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [scriptPath]
                try process.run()

                // Quit so the script can replace us
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "Update failed: \(error.localizedDescription)"
                    self.isUpdating = false
                }
            }
        }
    }
}

private func chmod(_ path: String, _ mode: mode_t) {
    Darwin.chmod(path, mode)
}
