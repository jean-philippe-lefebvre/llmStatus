import Foundation

/// Subscription usage limits (Claude plan, ChatGPT plan used by Codex).
struct SubscriptionUsage: Identifiable, Equatable {
    struct Window: Equatable {
        /// 0...100
        let percent: Double
        let resetsAt: Date?
        /// Window length; drives the label ("5h", "weekly").
        var seconds: Int?

        var label: String {
            switch seconds {
            case nil: "short"
            case let s? where s == 7 * 24 * 3600: "weekly"
            case let s? where s % (24 * 3600) == 0: "\(s / (24 * 3600))d"
            case let s?: "\(max(1, (s + 1800) / 3600))h"
            }
        }
    }

    enum Kind: String, CaseIterable, Codable {
        case claude, codex

        var name: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }

        /// What the local-log breakdown cannot see.
        var breakdownCaveat: String {
            switch self {
            case .claude: "claude.ai (web, mobile) and other devices are not included."
            case .codex: "Codex cloud tasks and machines not listed in Settings are not included."
            }
        }

        var dashboardURL: URL {
            switch self {
            case .claude: URL(string: "https://claude.ai/settings/usage")!
            case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
            }
        }
    }

    let kind: Kind
    var weekly: Window?
    /// Shorter rolling window (5 h today) when the plan has one.
    var session: Window?
    var plan: String?
    /// Set when usage could not be read; shown instead of the gauges.
    var error: String?
    /// Estimated split of the weekly window by app, then project (local logs, plus remote hosts for Codex).
    var breakdown: [UsageShare] = []
    /// Remote hosts that could not be read for the breakdown.
    var breakdownErrors: [String] = []
    /// The `UsageAccount` this row belongs to; nil only in tests.
    var accountID: UUID?
    /// The account's name in Settings; the kind's name when unset.
    var title: String?
    /// The login's access token is expired: the CLI renews it on its next request.
    var tokenExpired = false
    /// The login cannot be renewed (no refresh token left): only a new sign-in brings it back.
    var signedOut = false
    /// When the limits shown were read; older than now when they are kept through an error.
    var fetchedAt: Date?
    /// Last attempt, successful or not.
    var checkedAt: Date?
    /// Set on HTTP 429: automatic refreshes leave the account alone until then.
    var retryAfter: Date?
    /// `UsageAccount.source` the row was read from: a row fetched before the account was
    /// pointed elsewhere (another host, folder or kind) is never shown under it.
    var source: String?
    /// Free Codex resets available to this Mac's login (`CodexResets`); nil when unknown.
    var resetCredits: [CodexResets.Credit]?

    var id: String { accountID?.uuidString ?? kind.rawValue }
    var displayName: String { title ?? kind.name }
}

/// Reads the OAuth tokens the official CLIs already store locally. Never refreshes them:
/// rotating a refresh token here would sign the CLI out.
enum UsageFetcher {
    static let claudeURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let codexURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let weekSeconds = 7 * 24 * 3600

    static func fetch(_ kind: SubscriptionUsage.Kind) async -> SubscriptionUsage {
        switch kind {
        case .claude: await fetchClaude()
        case .codex: await fetchCodex()
        }
    }

    // MARK: - Claude

    private struct ClaudeCredentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let refreshToken: String?
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth?
    }

    private struct ClaudeResponse: Decodable {
        struct Limit: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        let five_hour: Limit?
        let seven_day: Limit?
    }

    static func fetchClaude() async -> SubscriptionUsage {
        var usage = SubscriptionUsage(kind: .claude)
        // The `security` CLI is on the item's ACL (Claude Code writes it that way), so no keychain prompt.
        guard let raw = runSecurity(["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              let oauth = try? JSONDecoder().decode(ClaudeCredentials.self, from: raw).claudeAiOauth
        else {
            usage.error = "Sign in to Claude Code"
            return usage
        }
        usage.plan = oauth.subscriptionType?.capitalized
        if let expiresAt = oauth.expiresAt, Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            usage.tokenExpired = true
            guard oauth.refreshToken?.isEmpty == false else {
                usage.error = ClaudeRenewal.signedOutMessage
                usage.signedOut = true
                return usage
            }
            // Claude Code renews its short-lived token only when it sends a request.
            usage.error = "Token expired: Claude Code renews it on its next request"
            return usage
        }
        var request = URLRequest(url: claudeURL)
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let data = await send(request, usage: &usage, relogin: "open Claude Code") else { return usage }
        return parseClaude(data, into: usage)
    }

    static func parseClaude(_ data: Data, into base: SubscriptionUsage = SubscriptionUsage(kind: .claude)) -> SubscriptionUsage {
        var usage = base
        guard let response = try? JSONDecoder().decode(ClaudeResponse.self, from: data),
              let weekly = window(response.seven_day) else {
            usage.error = "Unreadable usage data"
            return usage
        }
        usage.weekly = weekly
        usage.session = window(response.five_hour, seconds: 5 * 3600)
        return usage
    }

    private static func window(_ limit: ClaudeResponse.Limit?, seconds: Int = weekSeconds) -> SubscriptionUsage.Window? {
        guard let percent = limit?.utilization else { return nil }
        return .init(percent: percent, resetsAt: limit?.resets_at.flatMap(parseISODate), seconds: seconds)
    }

    // MARK: - Codex

    struct CodexAuth: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
        }
        let tokens: Tokens?
    }

    private struct CodexResponse: Decodable {
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Window: Decodable {
            let used_percent: Double
            let limit_window_seconds: Int?
            let reset_at: Double?
        }
        let plan_type: String?
        let rate_limit: RateLimit?
    }

    static func codexTokens() -> CodexAuth.Tokens? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let raw = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else { return nil }
        return try? JSONDecoder().decode(CodexAuth.self, from: raw).tokens
    }

    /// ChatGPT account of the local Codex login: remote hosts only count usage of this account.
    static func codexAccountID() -> String? { codexTokens()?.account_id }

    static func fetchCodex() async -> SubscriptionUsage {
        var usage = SubscriptionUsage(kind: .codex)
        guard let tokens = codexTokens() else {
            usage.error = "Sign in to Codex with ChatGPT"
            return usage
        }
        var request = URLRequest(url: codexURL)
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        if let account = tokens.account_id {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        async let credits = CodexResets.fetch()
        guard let data = await send(request, usage: &usage, relogin: "run codex") else { return usage }
        var parsed = parseCodex(data, into: usage)
        parsed.resetCredits = await credits
        return parsed
    }

    static func parseCodex(_ data: Data, into base: SubscriptionUsage = SubscriptionUsage(kind: .codex)) -> SubscriptionUsage {
        var usage = base
        guard let response = try? JSONDecoder().decode(CodexResponse.self, from: data) else {
            usage.error = "Unreadable usage data"
            return usage
        }
        usage.plan = response.plan_type?.capitalized
        // Primary/secondary are not fixed: a plan may only have a weekly window, sent as primary.
        let windows = [response.rate_limit?.primary_window, response.rate_limit?.secondary_window].compactMap { $0 }
        func convert(_ w: CodexResponse.Window) -> SubscriptionUsage.Window {
            .init(percent: w.used_percent, resetsAt: w.reset_at.map { Date(timeIntervalSince1970: $0) },
                  seconds: w.limit_window_seconds)
        }
        guard let weekly = windows.first(where: { ($0.limit_window_seconds ?? 0) >= weekSeconds }) else {
            usage.error = windows.isEmpty ? "No usage limit reported" : "No weekly limit reported"
            usage.session = windows.first.map(convert)
            return usage
        }
        usage.weekly = convert(weekly)
        usage.session = windows.first { ($0.limit_window_seconds ?? 0) < weekSeconds }.map(convert)
        return usage
    }

    // MARK: - Helpers

    private static func send(_ request: URLRequest, usage: inout SubscriptionUsage, relogin: String) async -> Data? {
        let source = "UsageFetcher.\(usage.kind.rawValue)"
        do {
            let (data, response) = try await HTTPClient.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                usage.error = "Session expired, \(relogin)"
                usage.tokenExpired = true
                return nil
            }
            if code == 429 {
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                FileLogger.shared.warning("HTTP 429, retry after \(wait.map { "\(Int($0)) s" } ?? "unknown")", source: source)
                usage.error = "Rate limited (429)"
                usage.retryAfter = Date().addingTimeInterval(min(max(wait ?? UsageMonitor.rateLimitPause, 60), 3600))
                return nil
            }
            guard (200...299).contains(code) else {
                FileLogger.shared.warning("HTTP \(code)", source: source)
                usage.error = "Usage unavailable (HTTP \(code))"
                return nil
            }
            return data
        } catch {
            FileLogger.shared.error("Fetch failed: \(error.localizedDescription)", source: source)
            usage.error = "Usage unavailable"
            return nil
        }
    }

    private static func runSecurity(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A locked keychain makes `security` wait for the user; never let that hold the refresh.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // Creating a formatter costs far more than parsing: the log scan parses tens of thousands of dates.
    // ISO8601DateFormatter is thread-safe once configured.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func parseISODate(_ value: String) -> Date? {
        if let date = fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value) { return date }
        // Python-style microseconds (".196176") are rejected by ISO8601DateFormatter; keep milliseconds.
        let trimmed = value.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return fractionalFormatter.date(from: trimmed)
    }
}

/// Keeps subscription usage fresh. Polled less often than status pages: limits move slowly.
@Observable
class UsageMonitor {
    var usages: [SubscriptionUsage] = []
    /// Accounts shown, by group. Changing them drops the rows of removed accounts at the next refresh.
    var groups: [UsageGroup] = [] {
        didSet { if groups != oldValue { generation += 1 } }
    }
    /// SSH hosts whose Codex usage joins the breakdown (disabled ones are kept but not read).
    var remoteHosts: [RemoteUsage.Host] = [] {
        didSet { if remoteHosts != oldValue { generation += 1 } }
    }
    /// Last check per host alias, shown in Settings.
    var hostStatus: [String: RemoteUsage.Status] = [:]
    /// Reads in flight per alias (poll and "Test" can overlap).
    private var inFlight: [String: Int] = [:]
    /// Latest request per alias: an older read finishing later must not overwrite its status.
    @ObservationIgnored private var latestRequest: [String: Int] = [:]

    /// Aliases being read right now.
    var checkingHosts: Set<String> { Set(inFlight.filter { $0.value > 0 }.keys) }
    /// Bumped when settings change: a refresh started before must not publish its breakdown.
    @ObservationIgnored private var generation = 0
    private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date?
    /// Pause after an HTTP 429 that gives no Retry-After.
    static let rateLimitPause: TimeInterval = 300

    /// Opening the popover shows fresh limits: refreshed when the last read is a minute old,
    /// or when a token was expired (the CLI may have renewed it since).
    @MainActor
    func refreshIfStale() async {
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > 60 } ?? true
        if stale || usages.contains(where: \.tokenExpired) { await refresh() }
    }

    var enabledAccounts: [UsageAccount] { groups.flatMap(\.accounts).filter(\.enabled) }

    /// Kinds of the enabled accounts logged in on this Mac (the ones with a log breakdown).
    var localKinds: Set<SubscriptionUsage.Kind> { Set(enabledAccounts.filter(\.isLocal).map(\.kind)) }

    /// Groups with at least one enabled account, each with the rows fetched so far.
    var sections: [(group: UsageGroup, usages: [SubscriptionUsage])] {
        groups.compactMap { group in
            let rows = group.accounts.filter(\.enabled).compactMap { account in
                usages.first { $0.accountID == account.id }
            }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    func startPolling(interval: TimeInterval = 300) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await refresh()
                // An expired token is renewed by the CLI at any moment: check again soon (keychain only).
                let wait = usages.contains(where: \.tokenExpired) ? min(interval, 60) : interval
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    @MainActor
    /// `force` (the Refresh button) also retries accounts paused after a rate limit.
    func refresh(force: Bool = false) async {
        lastRefresh = Date()
        let accounts = enabledAccounts
        usages.removeAll { usage in !accounts.contains { $0.id == usage.accountID && $0.source == usage.source } }
        // A rate-limited account is left alone until its pause ends: polling it again only extends the limit.
        let now = Date()
        let due = accounts.filter { account in
            force || (usages.first { $0.accountID == account.id }?.retryAfter).map { $0 <= now } ?? true
        }
        // A slow SSH host must not hold this Mac's rows or their breakdown back.
        async let remote: Void = fetch(due.filter { !$0.isLocal })
        await fetch(due.filter(\.isLocal))
        await refreshBreakdowns(accounts)
        await remote
    }

    @MainActor
    private func fetch(_ accounts: [UsageAccount]) async {
        await withTaskGroup(of: SubscriptionUsage.self) { group in
            for account in accounts {
                group.addTask {
                    // A remote login is read over ssh, which blocks: never on the main actor.
                    var usage = account.isLocal ? await UsageFetcher.fetch(account.kind) : RemoteAccountUsage.fetch(account)
                    usage.accountID = account.id
                    usage.source = account.source
                    return usage
                }
            }
            // Publish each subscription as soon as it lands, replacing only its own row,
            // so overlapping refreshes (poll, Refresh, toggle) never drop another row.
            for await result in group {
                var result = result
                result.checkedAt = Date()
                if result.error == nil { result.fetchedAt = result.checkedAt }
                if let previous = usages.first(where: { $0.id == result.id && $0.source == result.source }) {
                    result.breakdown = previous.breakdown
                    result.breakdownErrors = previous.breakdownErrors
                    result.resetCredits = result.resetCredits ?? previous.resetCredits
                    // An expired token or a network hiccup keeps the last limits read, dated.
                    if result.weekly == nil, previous.weekly != nil {
                        result.weekly = previous.weekly
                        result.session = previous.session
                        result.plan = result.plan ?? previous.plan
                        result.fetchedAt = previous.fetchedAt
                    }
                }
                publish(result)
            }
        }
    }

    /// The log scan takes seconds on a cold cache: percentages show first, the split follows.
    /// Only this Mac's logins have a breakdown: their logs are the local ones.
    @MainActor
    private func refreshBreakdowns(_ accounts: [UsageAccount]) async {
        let started = generation
        for kind in SubscriptionUsage.Kind.allCases {
            let rows = accounts.filter { $0.isLocal && $0.kind == kind }.map(\.id)
            guard let weekly = usages.first(where: { rows.contains($0.accountID ?? UUID()) })?.weekly else { continue }
            let length = TimeInterval(weekly.seconds ?? 7 * 24 * 3600)
            let start = (weekly.resetsAt ?? Date()).addingTimeInterval(-length)
            var remote = [RemoteUsage.Result]()
            if kind == .codex {
                remote = await fetchRemote(remoteHosts.filter(\.enabled), since: start)
            }
            let shares = await UsageBreakdown.shared.shares(
                for: kind, since: start, extra: remote.flatMap(\.records)
            )
            guard started == generation else { return }
            for index in usages.indices where rows.contains(usages[index].accountID ?? UUID()) {
                usages[index].breakdown = shares
                usages[index].breakdownErrors = remote.compactMap(\.error)
            }
        }
    }

    /// Accounts using a Codex reset right now, and the last reset error per account.
    var resetting: Set<UUID> = []
    var resetErrors: [UUID: String] = [:]

    /// Uses one free Codex reset of this Mac's login, then reads its limits again.
    @MainActor
    func useReset(_ creditID: String, for accountID: UUID) async {
        guard !resetting.contains(accountID),
              let account = enabledAccounts.first(where: { $0.id == accountID }),
              account.isLocal, account.kind == .codex else { return }
        resetting.insert(accountID)
        defer { resetting.remove(accountID) }
        resetErrors[accountID] = await CodexResets.consume(creditID)
        await fetch([account])
    }

    /// Accounts whose Claude Code login is being renewed (Renew button).
    var renewing: Set<UUID> = []

    /// Has the CLI renew this Mac's Claude login, then reads its limits again. A login the CLI
    /// cannot renew opens its sign-in in Terminal instead; polling picks up the new token.
    @MainActor
    func renew(_ accountID: UUID) async {
        guard !renewing.contains(accountID),
              let account = enabledAccounts.first(where: { $0.id == accountID }),
              account.isLocal, account.kind == .claude else { return }
        let index = { self.usages.firstIndex { $0.accountID == accountID } }
        if let i = index(), usages[i].signedOut {
            if let error = ClaudeRenewal.signIn() { usages[i].error = error }
            return
        }
        renewing.insert(accountID)
        defer { renewing.remove(accountID) }
        switch await ClaudeRenewal.renew() {
        case .renewed:
            await fetch([account])
        case .signedOut:
            guard let i = index() else { return }
            usages[i].error = ClaudeRenewal.signedOutMessage
            usages[i].signedOut = true
            usages[i].checkedAt = Date()
        case .failed(let error):
            guard let i = index() else { return }
            usages[i].error = error
            usages[i].checkedAt = Date()
        }
    }

    /// Reads one host now (Settings "Test"), updating its status only.
    @MainActor
    func check(_ host: RemoteUsage.Host) async {
        _ = await fetchRemote([host], since: Date().addingTimeInterval(-7 * 24 * 3600))
    }

    @MainActor
    private func fetchRemote(_ hosts: [RemoteUsage.Host], since start: Date) async -> [RemoteUsage.Result] {
        guard !hosts.isEmpty else { return [] }
        let account = UsageFetcher.codexAccountID()
        var tickets = [String: Int]()
        for alias in hosts.map(\.alias) {
            latestRequest[alias, default: 0] += 1
            tickets[alias] = latestRequest[alias]
            inFlight[alias, default: 0] += 1
        }
        defer { for alias in hosts.map(\.alias) { inFlight[alias, default: 1] -= 1 } }
        // ssh blocks; run every host concurrently off the main actor.
        let results = await withTaskGroup(of: (String, RemoteUsage.Result).self) { group in
            for host in hosts {
                group.addTask { (host.alias, RemoteUsage.fetch(host: host, since: start, accountID: account)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let current = Set(remoteHosts.map(\.alias))
        for (alias, result) in results where current.contains(alias) && latestRequest[alias] == tickets[alias] {
            hostStatus[alias] = RemoteUsage.Status(result)
        }
        return results.map(\.1)
    }

    private func publish(_ usage: SubscriptionUsage) {
        // An account removed or pointed elsewhere while its fetch was in flight keeps its new state.
        guard let account = enabledAccounts.first(where: { $0.id == usage.accountID }),
              usage.source == nil || usage.source == account.source else { return }
        var usage = usage
        usage.title = account.name
        usages.removeAll { $0.id == usage.id }
        usages.append(usage)
    }
}
