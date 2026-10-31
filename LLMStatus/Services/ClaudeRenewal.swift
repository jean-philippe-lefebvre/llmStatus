import AppKit

/// Renews this Mac's Claude Code token by sending one tiny request through the `claude` CLI.
/// The CLI refreshes its own login (with its own locking), so LLM Status never touches the
/// refresh token. Needed when sessions run in the Claude desktop app, whose login is separate
/// and never renews the CLI's keychain item.
enum ClaudeRenewal {
    /// Where installers put `claude`; a GUI app does not inherit the shell's PATH.
    static func candidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
    }

    /// Arguments of the renewing call: the smallest model, no session file left in the logs.
    static let arguments = ["-p", "--model", "haiku", "--no-session-persistence", "Reply with OK."]

    static func locateCLI() -> URL? {
        if let path = candidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the login shell's PATH (nvm, asdf and other version managers).
        guard let output = run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"], timeout: 10),
              output.status == 0 else { return nil }
        let path = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    enum Outcome: Equatable {
        case renewed
        /// The CLI has no refresh token left: only `claude auth login` brings the login back.
        case signedOut
        case failed(String)
    }

    static let signedOutMessage = "Claude Code is signed out: sign in again"

    static func renew() async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            guard let cli = locateCLI() else { return .failed("Claude Code CLI not found") }
            guard let output = run(cli, arguments, timeout: 90) else { return .failed("Claude Code did not answer") }
            guard output.status == 0 else {
                FileLogger.shared.error("Renew failed with status \(output.status)", source: "Claude")
                return isSignedOut(String(decoding: output.data, as: UTF8.self))
                    ? .signedOut : .failed("Claude Code could not renew its login: run claude in a terminal")
            }
            return .renewed
        }.value
    }

    /// What the CLI prints when its login cannot be refreshed any more.
    static func isSignedOut(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("could not be refreshed") || text.contains("not logged in") || text.contains("/login")
    }

    /// Opens `claude auth login` in Terminal (it needs the browser and may ask to paste a code).
    /// Nil when it opened, else a short reason for the row.
    static func signIn() -> String? {
        guard let cli = locateCLI() else { return "Claude Code CLI not found" }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-sign-in.command")
        let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = "#!/bin/zsh -l\n\(quoted) auth login --claudeai\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return "Could not open the Claude Code sign-in"
        }
        return NSWorkspace.shared.open(script) ? nil : "Could not open Terminal"
    }

    /// Runs a process from the temporary folder with stdin closed; nil when it could not start or timed out.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, data: Data)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        let directory = executable.deletingLastPathComponent().path
        environment["PATH"] = ([directory] + (environment["PATH"].map { [$0] } ?? ["/usr/bin:/bin"])).joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        // Errors are read too: they tell a login that cannot be refreshed from other failures.
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { timedOut = true; process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return timedOut ? nil : (process.terminationStatus, data)
    }
}
