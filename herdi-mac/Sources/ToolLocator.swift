import Foundation

/// Finds a command-line tool from a GUI app.
///
/// A packaged .app is launched by launchd with a minimal PATH — it does NOT get the user's shell
/// profile. So neither "just exec the name" nor "hardcode /opt/homebrew/bin/<tool>" works: the first
/// has no PATH to search, and the second misses every non-Homebrew install (version managers like
/// mise/asdf, ~/.local/bin, MacPorts). Both failure modes are silent, because Process.run() simply
/// throws and the usual `try?` discards it.
///
/// Resolution order, first hit wins:
///   1. an explicit override env var, if the caller names one (e.g. HERDR_BIN)
///   2. PATH — covers `swift run` during development and any GUI session with a usable PATH
///   3. the user's LOGIN shell (`$SHELL -l -c 'command -v <tool>'`), which sources their profile and
///      so resolves whatever their PATH manager set up. ~40ms, and cached.
///   4. well-known install locations
enum ToolLocator {
    private static var cache: [String: String] = [:]
    private static var loginPathCache: String??
    private static let lock = NSLock()

    /// The PATH from the user's login shell, i.e. the one they see in a terminal. Resolved once.
    static var loginShellPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return lockedLoginShellPath()
    }

    /// Caller must already hold `lock`. `lock` is a plain NSLock and so is NOT recursive: reading the
    /// public `loginShellPath` from inside `find()` (which holds the lock) deadlocks the calling
    /// thread. That froze the app during RelayConnection.init(), before it could even create its
    /// status item.
    private static func lockedLoginShellPath() -> String? {
        if let cached = loginPathCache { return cached }
        let value = readLoginShellPath()
        loginPathCache = .some(value)
        return value
    }

    private static func readLoginShellPath() -> String? {
        // -l sources the login profile; printf avoids a trailing newline surprise.
        loginShell(["-l", "-c", "printf %s \"$PATH\""])
    }

    /// Run the user's login shell and return trimmed stdout, or nil.
    ///
    /// Bounded by a deadline: this is called during app startup, and a profile that blocks (a prompt,
    /// a hung network mount, a version manager fetching) would otherwise freeze launch indefinitely.
    private static func loginShell(_ args: [String], timeout: TimeInterval = 5) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read on a background queue: waiting on the pipe and the exit in the wrong order can
        // deadlock on a full buffer.
        var data = Data()
        let reader = DispatchQueue(label: "herdi.toollocator.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        _ = done.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else { return nil }
        let out = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Environment for child processes: the current one, but with the login shell's PATH.
    ///
    /// Without this a spawned tool inherits launchd's minimal PATH, so anything it shells out to in
    /// turn can fail even when the tool itself was found by absolute path.
    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path = loginShellPath {
            // Keep any PATH the app already has — a dev running from a terminal should not lose it.
            if let existing = env["PATH"], !existing.isEmpty, existing != path {
                let merged = ([path] + existing.split(separator: ":").map(String.init))
                    .joined(separator: ":")
                env["PATH"] = merged
            } else {
                env["PATH"] = path
            }
        }
        return env
    }

    /// Absolute path to `tool`, or nil if it cannot be found anywhere.
    static func find(_ tool: String, overrideEnv: String? = nil, extraPaths: [String] = []) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[tool] { return hit }

        if let found = resolve(tool, overrideEnv: overrideEnv, extraPaths: extraPaths) {
            cache[tool] = found
            return found
        }
        return nil
    }

    /// Drop a cached result — used after a failed exec so a newly-installed tool is picked up.
    static func forget(_ tool: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: tool)
    }

    private static func resolve(_ tool: String, overrideEnv: String?, extraPaths: [String]) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        // 1. Explicit override. Honoured even if it does not exist, so a bad value surfaces as a
        //    clear "that path is not executable" rather than being silently ignored.
        if let key = overrideEnv, let override = env[key], !override.isEmpty {
            return override
        }

        // 2. The process PATH, then the LOGIN SHELL's PATH — the latter is what the user sees in a
        //    terminal, and the only one that knows about their PATH manager.
        for path in [env["PATH"], lockedLoginShellPath()].compactMap({ $0 }) {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                let candidate = "\(dir)/\(tool)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        // 3. Ask the login shell directly — catches shell functions/aliases resolving to a real path.
        if let found = loginShellWhich(tool), fm.isExecutableFile(atPath: found) { return found }

        // 4. Well-known locations.
        let home = fm.homeDirectoryForCurrentUser.path
        let known = extraPaths + [
            "\(home)/.local/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/usr/bin/\(tool)",
            "\(home)/.local/share/mise/shims/\(tool)",
            "\(home)/.asdf/shims/\(tool)",
            "/opt/local/bin/\(tool)",
        ]
        return known.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func loginShellWhich(_ tool: String) -> String? {
        guard let out = loginShell(["-l", "-c", "command -v \(tool)"]) else { return nil }
        // A login shell can print more than the path (profile noise); take the last absolute-looking
        // line.
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }
}
