import Foundation

/// Limits of a Claude or ChatGPT (Codex) login that lives on an SSH host. The usage API is called
/// from the host itself, so its token never leaves it; only the limits come back.
enum RemoteAccountUsage {
    /// Login user's name is passed so the script finds that user's home even under sudo.
    static let remoteCommand = #"cd / && U=$(id -un) && if sudo -n true 2>/dev/null; "#
        + #"then exec sudo -n /usr/bin/python3 -I - "$U"; else exec /usr/bin/python3 -I - "$U"; fi"#

    /// Absolute, or in the login user's home ("~/..."). Sent inside the script, never in the command.
    static func isValidFolder(_ folder: String) -> Bool {
        (folder.hasPrefix("/") || folder.hasPrefix("~/")) && !folder.contains(where: \.isNewline)
    }

    static func script(for account: UsageAccount) -> String {
        var config: [String: Any] = ["kind": account.kind.rawValue]
        if let folder = account.folder { config["folder"] = folder }
        let json = (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8)
        return "CONFIG_B64 = \"\(json.base64EncodedString())\"\n" + collector
    }

    static func fetch(_ account: UsageAccount) -> SubscriptionUsage {
        var usage = SubscriptionUsage(kind: account.kind, accountID: account.id, title: account.name)
        guard let host = account.host, RemoteUsage.isValidHost(host) else {
            usage.error = "Invalid SSH host"
            return usage
        }
        if let folder = account.folder, !isValidFolder(folder) {
            usage.error = "Invalid folder"
            return usage
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", host, remoteCommand]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            usage.error = "ssh unavailable"
            return usage
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            if process.isRunning { process.terminate() }
        }
        input.fileHandleForWriting.write(Data(script(for: account).utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            FileLogger.shared.warning("ssh \(host) exited \(process.terminationStatus)", source: "RemoteAccountUsage")
            usage.error = "\(host) unreachable"
            return usage
        }
        return parse(data, into: usage, host: host)
    }

    /// The script prints one JSON object: {"status", "plan", "body"} or {"error", "folder"?, "plan"?}.
    static func parse(_ data: Data, into base: SubscriptionUsage, host: String) -> SubscriptionUsage {
        var usage = base
        let line = data.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            usage.error = "Unreadable answer from \(host)"
            return usage
        }
        let cli = usage.kind == .claude ? "claude" : "codex"
        if let plan = object["plan"] as? String { usage.plan = plan.capitalized }
        if let error = object["error"] as? String {
            let folder = object["folder"] as? String ?? "?"
            usage.error = switch error {
            case "missing": "No \(usage.kind.name) login in \(folder) on \(host)"
            case "unreadable": "Cannot read \(folder) on \(host)"
            case "expired" where object["renewable"] as? Bool == false:
                ClaudeRenewal.signedOutMessage(host: host)
            case "expired": "Token expired on \(host), run \(cli) there"
            default: "Usage unavailable from \(host)"
            }
            if error == "expired", usage.kind == .claude {
                usage.tokenExpired = true
                usage.signedOut = object["renewable"] as? Bool == false
            }
            return usage
        }
        let status = (object["status"] as? NSNumber)?.intValue ?? 0
        if status == 401 || status == 403 {
            usage.error = "Session expired on \(host), run \(cli) there"
            return usage
        }
        if status == 429 {
            usage.error = "Rate limited (429)"
            usage.retryAfter = Date().addingTimeInterval(UsageMonitor.rateLimitPause)
            return usage
        }
        guard (200...299).contains(status), let body = object["body"],
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            usage.error = "Usage unavailable (HTTP \(status))"
            return usage
        }
        let plan = usage.plan
        usage = usage.kind == .claude ? UsageFetcher.parseClaude(bodyData, into: usage) : UsageFetcher.parseCodex(bodyData, into: usage)
        if usage.plan == nil { usage.plan = plan }
        return usage
    }

    /// A login found on a host, offered in the account editor.
    struct Login: Hashable {
        /// "~/.claude" when in the login user's home, else absolute.
        let folder: String
        /// Plan and token state, e.g. "Team · expired".
        let detail: String
    }

    /// Claude or Codex logins on a host (reads the login files' plan and expiry only). Nil error when the search ran.
    static func findLogins(host: String, kind: SubscriptionUsage.Kind) -> (logins: [Login], error: String?) {
        guard RemoteUsage.isValidHost(host) else { return ([], "Invalid SSH host") }
        let json = (try? JSONSerialization.data(withJSONObject: ["kind": kind.rawValue])) ?? Data("{}".utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", host, remoteCommand]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ([], "ssh unavailable") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            if process.isRunning { process.terminate() }
        }
        input.fileHandleForWriting.write(Data(("CONFIG_B64 = \"\(json.base64EncodedString())\"\n" + finder).utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return ([], "\(host) unreachable") }
        return (parseLogins(data), nil)
    }

    /// The default folder (~/.claude, ~/.codex) first, then by folder.
    static func parseLogins(_ data: Data) -> [Login] {
        let logins: [Login] = data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let folder = object["folder"] as? String else { return nil }
            let plan = (object["plan"] as? String)?.capitalized
            let state = (object["expired"] as? Bool).map { $0 ? "expired" : "valid" }
            return Login(folder: folder, detail: [plan, state].compactMap { $0 }.joined(separator: " · "))
        }
        return logins.sorted { a, b in
            let defaults = ["~/.claude", "~/.codex"]
            return (defaults.contains(a.folder) ? 0 : 1, a.folder) < (defaults.contains(b.folder) ? 0 : 1, b.folder)
        }
    }

    /// Runs like `collector`; lists the folders holding a login of the kind, the login user's own first.
    static let finder = #"""
import base64, json, os, pwd, sys, time

kind = json.loads(base64.b64decode(CONFIG_B64))["kind"]
home = pwd.getpwnam(sys.argv[1]).pw_dir if len(sys.argv) > 1 else os.path.expanduser("~")
name = ".credentials.json" if kind == "claude" else "auth.json"
roots = [(home, 4)] + ([("/home", 5), ("/root", 4), ("/srv", 5), ("/opt", 4)] if os.geteuid() == 0 else [])
skip = {"node_modules", ".git", ".cache", ".npm", ".venv", "venv", "sessions", "projects"}
seen, deadline = set(), time.time() + 15
for root, depth in roots:
    base = root.rstrip("/").count("/")
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in skip] if folder.count("/") - base < depth else []
        if time.time() > deadline:
            break
        if name not in files or os.path.realpath(folder) in seen:
            continue
        seen.add(os.path.realpath(folder))
        try:
            with open(os.path.join(folder, name)) as f:
                data = json.load(f)
        except Exception:
            continue
        shown = "~" + folder[len(home):] if folder == home or folder.startswith(home + "/") else folder
        if kind == "claude":
            oauth = data.get("claudeAiOauth") if isinstance(data, dict) else None
            if isinstance(oauth, dict) and oauth.get("accessToken"):
                expires = oauth.get("expiresAt")
                print(json.dumps({"folder": shown, "plan": oauth.get("subscriptionType"),
                                  "expired": bool(expires and expires / 1000 < time.time())}))
        elif isinstance(data, dict) and isinstance(data.get("tokens"), dict) and data["tokens"].get("access_token"):
            print(json.dumps({"folder": shown}))
"""#

    /// Runs on the host with `python3 -I - <login user>`, after a `CONFIG_B64 = "..."` line.
    /// Reads the login file, calls the usage API with it, and prints the limits only.
    static let collector = #"""
import base64, json, os, pwd, sys, time, urllib.error, urllib.request

CONFIG = json.loads(base64.b64decode(CONFIG_B64))
kind = CONFIG["kind"]
home = pwd.getpwnam(sys.argv[1]).pw_dir if len(sys.argv) > 1 else os.path.expanduser("~")
folder = CONFIG.get("folder") or ("~/.claude" if kind == "claude" else "~/.codex")
if folder.startswith("~/"):
    folder = os.path.join(home, folder[2:])
elif not folder.startswith("/"):
    out(error="unreadable", folder=folder)

def out(**fields):
    print(json.dumps(fields))
    sys.exit(0)

def load(name):
    try:
        with open(os.path.join(folder, name)) as f:
            return json.load(f)
    except FileNotFoundError:
        out(error="missing", folder=folder)
    except Exception:
        out(error="unreadable", folder=folder)

def call(url, headers):
    headers["User-Agent"] = "llm-status"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except Exception as exc:
        out(error="network")

if kind == "claude":
    oauth = (load(".credentials.json") or {}).get("claudeAiOauth") or {}
    if not oauth.get("accessToken"):
        out(error="missing", folder=folder)
    plan = oauth.get("subscriptionType")
    if oauth.get("expiresAt") and oauth["expiresAt"] / 1000 < time.time():
        out(error="expired", plan=plan, renewable=bool(oauth.get("refreshToken")))
    status, body = call("https://api.anthropic.com/api/oauth/usage",
                        {"Authorization": "Bearer " + oauth["accessToken"], "anthropic-beta": "oauth-2025-04-20"})
    keep = ("five_hour", "seven_day")
else:
    tokens = (load("auth.json") or {}).get("tokens") or {}
    if not tokens.get("access_token"):
        out(error="missing", folder=folder)
    headers = {"Authorization": "Bearer " + tokens["access_token"]}
    if tokens.get("account_id"):
        headers["ChatGPT-Account-Id"] = tokens["account_id"]
    status, body = call("https://chatgpt.com/backend-api/wham/usage", headers)
    plan, keep = None, ("plan_type", "rate_limit")
# Only the limits: the API also returns the account's email and ids.
out(status=status, plan=plan, body={k: body.get(k) for k in keep} if isinstance(body, dict) else None)
"""#
}
