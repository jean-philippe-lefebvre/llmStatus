import Foundation

@Observable
class StatusMonitor {
    var providers: [ServiceProvider]
    let notificationManager = NotificationManager()
    /// Weekly limits of the Claude / Codex subscriptions (independent of status pages)
    let usage = UsageMonitor()
    /// Servers checked by this app (Settings > Servers)
    let infra = InfraMonitor()
    var notificationsEnabled = true
    var notifyProviderID = "all"
    /// True during manual force-refresh (disables Refresh button, shows "Refreshing...")
    var isRefreshing = false
    /// True during any fetch cycle (auto or manual) — shows spinner in footer
    var isPolling = false
    private var pollingTask: Task<Void, Never>?

    /// Timestamp of the last completed fetch cycle
    var lastFullCheck: Date?

    /// IDs of disabled providers — synced from AppSettings
    var disabledProviderIDs: Set<String> = []

    /// Custom display order (provider IDs). Empty = default order.
    var providerOrderIDs: [String] = []

    /// Watched component name per provider. If set, provider status = component status.
    var watchedComponentMap: [String: String] = [:]

    /// Only enabled providers, respecting custom order with issues bumped to top.
    var enabledProviders: [ServiceProvider] {
        let enabled = providers.filter { !disabledProviderIDs.contains($0.id) }
        let ordered = providerOrderIDs.isEmpty ? enabled : {
            let lookup = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
            return providerOrderIDs.compactMap { lookup[$0] }
                + enabled.filter { !providerOrderIDs.contains($0.id) }
        }()

        // Stable partition: issues first, then the rest in custom order
        return ordered.filter { $0.currentStatus.severity >= 2 }
            + ordered.filter { $0.currentStatus.severity < 2 }
    }

    /// Worst status across enabled providers (highest severity wins).
    var aggregatedStatus: ServiceStatus {
        let active = enabledProviders
        guard !active.isEmpty else { return .unknown }
        return active
            .map(\.currentStatus)
            .max(by: { $0.severity < $1.severity }) ?? .unknown
    }

    /// Status for the menu bar icon — either a specific provider or aggregated.
    /// A server problem shows whichever provider is selected.
    func menuBarStatus(for providerID: String) -> ServiceStatus {
        let status = providerID == "all"
            ? aggregatedStatus
            : providers.first { $0.id == providerID }?.currentStatus ?? .unknown
        guard let issue = infra.issueStatus, issue.severity > status.severity else { return status }
        return issue
    }

    /// Short label for the menu bar — provider short name or "LLM".
    func menuBarLabel(for providerID: String) -> String {
        if providerID == "all" {
            return "LLM"
        }
        return providers.first { $0.id == providerID }?.shortName ?? "LLM"
    }

    init() {
        self.providers = Self.defaultProviders()
    }

    /// Update the custom display order (enabledProviders uses this).
    func reorderProviders(orderedIDs: [String]) {
        providerOrderIDs = orderedIDs
    }

    /// Return providers sorted by the given ID order (unordered providers appended at end).
    func orderedProviders(by orderIDs: [String]) -> [ServiceProvider] {
        guard !orderIDs.isEmpty else { return providers }
        let lookup = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let fromOrder = orderIDs.compactMap { lookup[$0] }
        let remaining = providers.filter { p in !orderIDs.contains(p.id) }
        return fromOrder + remaining
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 300) {
        stopPolling()
        pollingTask = Task {
            // Fetch immediately on start
            await fetchAllStatuses()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await fetchAllStatuses()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Refresh only if there are enabled providers with unknown status (newly enabled)
    func refreshIfNeeded() async {
        let needsFetch = providers.contains { provider in
            !disabledProviderIDs.contains(provider.id) && provider.currentStatus == .unknown
        }
        guard needsFetch else { return }
        await fetchAllStatuses()
    }

    /// Manual refresh — invalidates caches and resets all providers to loading state
    func forceRefresh() async {
        isRefreshing = true
        XAIFetcher.invalidateCache()
        for index in providers.indices {
            providers[index].currentStatus = .unknown
            providers[index].statusDetail = "Refreshing..."
        }
        async let usageRefresh: Void = usage.refresh(force: true)
        async let infraRefresh: Void = infra.refreshAll()
        await fetchAllStatuses()
        await usageRefresh
        await infraRefresh
        isRefreshing = false
    }

    func fetchAllStatuses() async {
        isPolling = true
        notificationManager.purgeStaleEntries()

        // Show progress for slow fetchers (xAI uses a headless browser)
        for (index, provider) in providers.enumerated() {
            if disabledProviderIDs.contains(provider.id) { continue }
            if provider.fetcherType == .xai && !XAIFetcher.hasCachedResult {
                providers[index].statusDetail = "Launching browser..."
            }
        }

        await withTaskGroup(of: (Int, ServiceStatus, [Incident], [ServiceComponent]).self) { group in
            for (index, provider) in providers.enumerated() {
                guard !disabledProviderIDs.contains(provider.id) else { continue }
                let fetcherType = provider.fetcherType
                let baseURL = provider.apiBaseURL
                group.addTask {
                    let status: ServiceStatus
                    let incidents: [Incident]
                    let components: [ServiceComponent]

                    switch fetcherType {
                    case .statuspage:
                        async let s = StatusFetcher.fetchStatus(baseURL: baseURL)
                        async let i = StatusFetcher.fetchIncidents(baseURL: baseURL)
                        async let c = StatusFetcher.fetchComponents(baseURL: baseURL)
                        let response = await s
                        status = response.map { ServiceStatus(fromIndicator: $0.status.indicator) } ?? .unknown
                        incidents = await i
                        components = await c
                    case .groq:
                        async let s = GroqFetcher.fetchStatus(baseURL: baseURL)
                        async let i = GroqFetcher.fetchIncidents(baseURL: baseURL)
                        status = await s
                        incidents = await i
                        components = []
                    case .google:
                        async let s = GoogleFetcher.fetchStatus(baseURL: baseURL)
                        async let i = GoogleFetcher.fetchIncidents(baseURL: baseURL)
                        status = await s
                        incidents = await i
                        components = []
                    case .htmlStatus:
                        async let s = HTMLStatusFetcher.fetchStatus(baseURL: baseURL)
                        async let i = HTMLStatusFetcher.fetchIncidents(baseURL: baseURL)
                        async let c = HTMLStatusFetcher.fetchComponents(baseURL: baseURL)
                        status = await s
                        incidents = await i
                        components = await c
                    case .openrouter:
                        let snapshot = await OpenRouterFetcher.fetch(baseURL: baseURL)
                        status = snapshot.status
                        incidents = []
                        components = snapshot.components
                    case .xai:
                        async let s = XAIFetcher.fetchStatus(baseURL: baseURL)
                        async let i = XAIFetcher.fetchIncidents(baseURL: baseURL)
                        status = await s
                        incidents = await i
                        components = []
                    }

                    return (index, status, incidents, components)
                }
            }

            for await (index, status, incidents, components) in group {
                let previousStatus = providers[index].currentStatus
                providers[index].incidents = incidents
                providers[index].components = components
                providers[index].lastChecked = Date()

                // If a watched component is set, use its status instead of overall
                let providerID = providers[index].id
                let effectiveStatus: ServiceStatus
                if let watchedName = watchedComponentMap[providerID],
                   let componentStatus = findComponentStatus(named: watchedName, in: components) {
                    effectiveStatus = componentStatus
                } else {
                    effectiveStatus = Self.elevateStatus(status, withActiveIncidents: incidents)
                }
                providers[index].currentStatus = effectiveStatus
                providers[index].statusDetail = (effectiveStatus == .unknown) ? "Unable to fetch status" : nil

                // Notify only for the prioritized provider (or all)
                guard notificationsEnabled else { continue }
                guard notifyProviderID == "all" || notifyProviderID == providerID else { continue }

                // Recovery notification: was degraded/outage, now operational
                if effectiveStatus == .operational
                    && previousStatus != .operational
                    && previousStatus != .unknown {
                    await notificationManager.sendRecoveryNotification(
                        providerName: providers[index].name,
                        providerID: providerID
                    )
                } else if effectiveStatus != .operational && effectiveStatus != .unknown {
                    // Provider went down — reset recovery tracking so next recovery triggers
                    notificationManager.clearRecovery(providerID: providerID)
                }

                for incident in incidents where incident.isActive {
                    await notificationManager.sendIncidentNotification(
                        providerName: providers[index].name,
                        providerID: providerID,
                        incident: incident
                    )
                }
            }
        }

        lastFullCheck = Date()
        isPolling = false
    }

    /// Elevate a reported provider status when active incidents are present.
    /// Some status pages (e.g. OpenAI) clear the global indicator while an incident
    /// is still in `monitoring`, leaving the app green despite a visible problem.
    static func elevateStatus(_ reported: ServiceStatus, withActiveIncidents incidents: [Incident]) -> ServiceStatus {
        let active = incidents.filter(\.isActive)
        guard !active.isEmpty else { return reported }
        let fromIncidents: ServiceStatus = active.map { incident -> ServiceStatus in
            switch incident.impact {
            case .critical: .critical
            case .major:    .majorOutage
            case .minor:    .degraded
            case .none:     .degraded
            }
        }.max(by: { $0.severity < $1.severity }) ?? reported
        return [reported, fromIncidents].max(by: { $0.severity < $1.severity }) ?? reported
    }

    /// Find a component's status by name, searching in groups and flat components.
    private func findComponentStatus(named name: String, in components: [ServiceComponent]) -> ServiceStatus? {
        // Check groups first (e.g. "APIs" group → worst status of children)
        for component in components {
            if component.isGroup && component.name == name {
                return component.status
            }
            // Check children inside groups
            if component.isGroup {
                if let child = component.children.first(where: { $0.name == name }) {
                    return child.status
                }
            }
            // Check flat components
            if component.name == name {
                return component.status
            }
        }
        return nil
    }

    // MARK: - Default Providers

    private static func defaultProviders() -> [ServiceProvider] {
        [
            ServiceProvider(
                id: "anthropic",
                name: "Anthropic (Claude)",
                shortName: "Claude",
                statusURL: URL(string: "https://status.anthropic.com")!,
                apiBaseURL: URL(string: "https://status.anthropic.com/api/v2")!,
                fetcherType: .statuspage,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "openai",
                name: "OpenAI",
                shortName: "OpenAI",
                statusURL: URL(string: "https://status.openai.com")!,
                apiBaseURL: URL(string: "https://status.openai.com/api/v2")!,
                fetcherType: .statuspage,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "cursor",
                name: "Cursor",
                shortName: "Cursor",
                statusURL: URL(string: "https://status.cursor.com")!,
                apiBaseURL: URL(string: "https://status.cursor.com/api/v2")!,
                fetcherType: .statuspage,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "google",
                name: "Google (Gemini)",
                shortName: "Gemini",
                statusURL: URL(string: "https://status.cloud.google.com")!,
                apiBaseURL: URL(string: "https://status.cloud.google.com")!,
                fetcherType: .google,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "mistral",
                name: "Mistral AI",
                shortName: "Mistral",
                statusURL: URL(string: "https://status.mistral.ai")!,
                apiBaseURL: URL(string: "https://status.mistral.ai")!,
                fetcherType: .htmlStatus,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "deepseek",
                name: "DeepSeek",
                shortName: "DeepSeek",
                statusURL: URL(string: "https://status.deepseek.com")!,
                apiBaseURL: URL(string: "https://status.deepseek.com/api/v2")!,
                fetcherType: .statuspage,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "moonshot",
                name: "Moonshot AI",
                shortName: "Moonshot",
                statusURL: URL(string: "https://status.moonshot.cn")!,
                apiBaseURL: URL(string: "https://status.moonshot.cn/api/v2")!,
                fetcherType: .statuspage,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "openrouter",
                name: "OpenRouter",
                shortName: "OpenRouter",
                statusURL: URL(string: "https://status.openrouter.ai")!,
                apiBaseURL: URL(string: "https://status.openrouter.ai")!,
                fetcherType: .openrouter,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "perplexity",
                name: "Perplexity",
                shortName: "Perplexity",
                statusURL: URL(string: "https://status.perplexity.ai")!,
                apiBaseURL: URL(string: "https://status.perplexity.ai")!,
                fetcherType: .htmlStatus,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
            ServiceProvider(
                id: "xai",
                name: "xAI (Grok)",
                shortName: "Grok",
                statusURL: URL(string: "https://status.x.ai")!,
                apiBaseURL: URL(string: "https://status.x.ai")!,
                fetcherType: .xai,
                currentStatus: .unknown,
                lastChecked: nil,
                incidents: []
            ),
        ]
    }
}
