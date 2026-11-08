import AppKit

/// Renews a Claude Code token by sending one tiny request through the `claude` CLI, on this Mac
/// or over SSH on the account's host. The CLI refreshes its own login (with its own locking), so
/// LLM Status never touches the refresh token. Needed when sessions run in the Claude desktop
/// app, whose login is separate and never renews the CLI's keychain item, or when a host's agent
/// uses another login.
enum ClaudeRenewal {
    /// Where installers put `claude`; a GUI app does not inherit the shell's PATH.
    static func candidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
    }

    /// Arguments of the renewing call: the smallest model, no session file left in the logs.
    /// It counts against the plan and starts its 5-hour window, so it is only the fallback.
    static let arguments = ["-p", "--model", "haiku", "--no-session-persistence", "Reply with OK."]
    /// Tried first: `/usage` reads the plan's limits through the CLI's login, which refreshes the
    /// token on the way, with no model request (nothing counted, no window started).
    static let lightArguments = ["-p", "--no-session-persistence", "/usage"]

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

    static func signedOutMessage(host: String?) -> String {
        host.map { "Claude Code is signed out on \($0): sign in again" } ?? signedOutMessage
    }

    static func renew(_ account: UsageAccount, light: Bool = false) async -> Outcome {
        let arguments = light ? lightArguments : arguments
        guard let host = account.host else { return await renew(arguments) }
        return await Task.detached(priority: .userInitiated) {
            guard RemoteUsage.isValidHost(host) else { return .failed("Invalid SSH host") }
            guard let output = run(URL(fileURLWithPath: "/usr/bin/ssh"),
                                   ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", host, "sh -s"],
                                   input: remoteScript(folder: account.folder, arguments: arguments), timeout: 90)
            else { return .failed("\(host) did not answer") }
            switch output.status {
            case 0: return .renewed
            case 127: return .failed("Claude Code CLI not found on \(host)")
            case 255: return .failed("\(host) unreachable")
            default:
                FileLogger.shared.error("Renew on \(host) failed with status \(output.status)", source: "Claude")
                return isSignedOut(String(decoding: output.data, as: UTF8.self))
                    ? .signedOut : .failed("Claude Code could not renew its login on \(host)")
            }
        }.value
    }

    /// POSIX sh run on the host: finds `claude` (installers, then the login shell's PATH) and sends
    /// the renewing call from /tmp, on the account's folder when it is not ~/.claude.
    static func remoteScript(folder: String?, arguments: [String] = arguments) -> String {
        var lines = ["cd /tmp 2>/dev/null"]
        if let folder, RemoteAccountUsage.isValidFolder(folder) {
            let path = folder.hasPrefix("~/") ? "$HOME/" + shellQuote(String(folder.dropFirst(2))) : shellQuote(folder)
            lines.append("CLAUDE_CONFIG_DIR=\(path); export CLAUDE_CONFIG_DIR")
        }
        lines += [
            "CLAUDE=",
            #"for c in "$HOME/.local/bin/claude" /usr/local/bin/claude /usr/bin/claude "$HOME/.npm-global/bin/claude" "$HOME/.bun/bin/claude"; do"#,
            #"  if [ -x "$c" ]; then CLAUDE="$c"; break; fi"#,
            "done",
            #"[ -n "$CLAUDE" ] || CLAUDE=$("${SHELL:-/bin/sh}" -lc 'command -v claude' 2>/dev/null)"#,
            #"[ -n "$CLAUDE" ] || exit 127"#,
            "exec \"$CLAUDE\" " + arguments.map(shellQuote).joined(separator: " ") + " </dev/null 2>&1",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func renew(_ arguments: [String] = arguments) async -> Outcome {
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

    /// Opens `claude auth login` in Terminal (it needs the browser and may ask to paste a code),
    /// over `ssh -t` for an account on a host. Nil when it opened, else a short reason for the row.
    static func signIn(_ account: UsageAccount? = nil) -> String? {
        let command: String
        if let host = account?.host {
            guard RemoteUsage.isValidHost(host) else { return "Invalid SSH host" }
            var remote = "cd /tmp; "
            if let folder = account?.folder, RemoteAccountUsage.isValidFolder(folder) {
                let path = folder.hasPrefix("~/") ? "$HOME/" + shellQuote(String(folder.dropFirst(2))) : shellQuote(folder)
                remote += "export CLAUDE_CONFIG_DIR=\(path); "
            }
            remote += #"exec "${SHELL:-/bin/sh}" -lc 'claude auth login --claudeai'"#
            command = "/usr/bin/ssh -t -- \(shellQuote(host)) \(shellQuote(remote))"
        } else {
            guard let cli = locateCLI() else { return "Claude Code CLI not found" }
            command = "\(shellQuote(cli.path)) auth login --claudeai"
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-sign-in.command")
        let body = "#!/bin/zsh -l\n\(command)\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return "Could not open the Claude Code sign-in"
        }
        return NSWorkspace.shared.open(script) ? nil : "Could not open Terminal"
    }

    /// Runs a process from the temporary folder, stdin closed or fed `input`; nil when it could not start or timed out.
    private static func run(_ executable: URL, _ arguments: [String], input: String? = nil,
                            timeout: TimeInterval) -> (status: Int32, data: Data)? {
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
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        if let inputPipe, let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { timedOut = true; process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return timedOut ? nil : (process.terminationStatus, data)
    }
}
