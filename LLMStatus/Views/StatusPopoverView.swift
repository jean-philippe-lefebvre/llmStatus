import SwiftUI

struct StatusPopoverView: View {
    let monitor: StatusMonitor
    let settings: AppSettings
    let network: NetworkMonitor
    @State private var showingSettings = false
    /// Usage groups folded in the popover, by id.
    @AppStorage("collapsedUsageGroups") private var collapsedUsageGroups = ""
    /// Provider whose components are shown in place of the gallery.
    @State private var selectedProviderID: String?
    /// Server whose checks are shown in place of the gallery.
    @State private var selectedMonitorID: UUID?

    private var selectedProvider: ServiceProvider? {
        monitor.enabledProviders.first { $0.id == selectedProviderID }
    }

    private let galleryColumns = [
        GridItem(.flexible(), spacing: 8, alignment: .top),
        GridItem(.flexible(), spacing: 8, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingSettings {
                // Settings header
                HStack {
                    Button {
                        showingSettings = false
                        // Refresh providers that may have been newly enabled
                        Task { await monitor.refreshIfNeeded() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    Text("Settings")
                        .font(.headline)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                // Forms scroll on their own: give them the room the screen allows.
                SettingsView(settings: settings, monitor: monitor)
                    .frame(height: min(640, FittingScrollView<EmptyView>.maxHeight))
            } else if let id = selectedMonitorID {
                detailHeader("Servers") { selectedMonitorID = nil }

                Divider()

                FittingScrollView {
                    monitorDetail(id)
                        .padding(12)
                }
            } else if let provider = selectedProvider {
                HStack {
                    Button {
                        selectedProviderID = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    Text("Status")
                        .font(.headline)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                FittingScrollView {
                    ProviderDetailView(provider: provider)
                        .padding(12)
                }
            } else {
                // Header
                HStack {
                    MenuBarIconView(status: monitor.menuBarStatus(for: settings.menuBarProvider))
                    Text("LLM Status")
                        .font(.headline)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                // Offline banner
                if !network.isConnected {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                        Text("No connection — status may be outdated")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    Divider()
                }

                // Subscription usage + provider list share one scroll area (the usage fold can grow)
                FittingScrollView {
                    VStack(spacing: 0) {
                    let sections = monitor.usage.sections
                    if !sections.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sections, id: \.group.id) { section in
                                // A single group needs no header: the rows read as before groups existed.
                                if sections.count > 1 {
                                    usageGroupHeader(section.group)
                                }
                                if sections.count == 1 || !isCollapsed(section.group) {
                                    ForEach(section.usages) { usage in
                                        UsageRowView(usage: usage, renew: renewAction(usage, in: section.group),
                                                     renewing: usage.accountID.map(monitor.usage.renewing.contains) ?? false,
                                                     useReset: resetAction(usage, in: section.group),
                                                     resetting: usage.accountID.map(monitor.usage.resetting.contains) ?? false,
                                                     resetError: usage.accountID.flatMap { monitor.usage.resetErrors[$0] })
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        Divider()
                    }

                    monitorSections

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: galleryColumns, spacing: 8) {
                            ForEach(monitor.enabledProviders) { provider in
                                ProviderCardView(provider: provider)
                                    .onTapGesture { selectedProviderID = provider.id }
                            }
                        }
                    }
                    .padding(12)
                    }
                }

                Divider()

                // Footer
                HStack(spacing: 12) {
                    Button {
                        Task { await monitor.forceRefresh() }
                    } label: {
                        HStack(spacing: 4) {
                            if monitor.isPolling {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(monitor.isRefreshing)

                    if let lastCheck = monitor.lastFullCheck {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.relativeTime(from: lastCheck))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("Quit")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 320)
        .focusable(false)
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            selectedProviderID = nil
            selectedMonitorID = nil
            showingSettings = true
        }
    }

    // MARK: - Servers

    @ViewBuilder
    private var monitorSections: some View {
        let infra = monitor.infra
        let servers = infra.ordered(infra.enabledServers)
        if !servers.isEmpty {
            monitorGrid("Servers") {
                ForEach(servers) { server in
                    MonitorCardView(name: server.displayName, result: infra.results[server.id],
                                    checking: infra.checking.contains(server.id))
                        .onTapGesture { selectedMonitorID = server.id }
                }
            }
            .padding(12)

            Divider()
        }
    }

    private func monitorGrid<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: galleryColumns, spacing: 8, content: content)
        }
    }

    @ViewBuilder
    private func monitorDetail(_ id: UUID) -> some View {
        let infra = monitor.infra
        let recheck = { Task { await infra.check(id: id) } }
        if let server = infra.servers.first(where: { $0.id == id }) {
            MonitorDetailView(name: server.displayName, subtitle: "ssh \(server.alias)", result: infra.results[id],
                              checking: infra.checking.contains(id), recheck: { _ = recheck() })
        }
    }

    private func detailHeader(_ title: String, back: @escaping () -> Void) -> some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .focusable(false)

            Text(title)
                .font(.headline)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func isCollapsed(_ group: UsageGroup) -> Bool {
        collapsedUsageGroups.split(separator: ",").contains { $0 == group.id.uuidString }
    }

    /// Only this Mac's Claude login can be renewed here: the CLI that owns it runs on this Mac.
    private func renewAction(_ usage: SubscriptionUsage, in group: UsageGroup) -> (() -> Void)? {
        guard let id = usage.accountID,
              let account = group.accounts.first(where: { $0.id == id }),
              account.isLocal, account.kind == .claude else { return nil }
        return { Task { await monitor.usage.renew(id) } }
    }

    /// Only this Mac's Codex login: its token is the one that can use the account's resets.
    private func resetAction(_ usage: SubscriptionUsage, in group: UsageGroup) -> ((CodexResets.Credit) -> Void)? {
        guard let id = usage.accountID,
              let account = group.accounts.first(where: { $0.id == id }),
              account.isLocal, account.kind == .codex else { return nil }
        return { credit in Task { await monitor.usage.useReset(credit.id, for: id) } }
    }

    private func usageGroupHeader(_ group: UsageGroup) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isCollapsed(group) ? 0 : 90))
            Text(group.name)
                .font(.caption.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            var ids = Set(collapsedUsageGroups.split(separator: ",").map(String.init))
            if !ids.insert(group.id.uuidString).inserted { ids.remove(group.id.uuidString) }
            withAnimation(.easeInOut(duration: 0.2)) {
                collapsedUsageGroups = ids.sorted().joined(separator: ",")
            }
        }
    }

    static func relativeTime(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
