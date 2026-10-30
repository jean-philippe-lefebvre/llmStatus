import Foundation
import ServiceManagement
import SwiftUI

@Observable
class AppSettings {
    @ObservationIgnored
    @AppStorage("refreshInterval") var refreshInterval: TimeInterval = 60 {
        didSet {
            if oldValue != refreshInterval { onMonitorSettingChange?(.refreshInterval(refreshInterval)) }
        }
    }
    @ObservationIgnored
    @AppStorage("launchAtLogin") private var launchAtLoginPreference: Bool = false
    private var launchAtLoginTick = 0
    var launchAtLoginStatusMessage: String?
    @ObservationIgnored
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true {
        didSet {
            if oldValue != notificationsEnabled { onMonitorSettingChange?(.notificationsEnabled(notificationsEnabled)) }
        }
    }
    /// Runtime side effects are wired at launch, independent of the popover's view lifecycle.
    @ObservationIgnored var onMonitorSettingChange: ((MonitorSettingChange) -> Void)?

    /// Polling starts last, so its first fetch already skips disabled providers.
    func applyMonitorSettings() {
        onMonitorSettingChange?(.disabledProviders(disabledProviderIDs))
        onMonitorSettingChange?(.notificationsEnabled(notificationsEnabled))
        onMonitorSettingChange?(.menuBarProvider(menuBarProvider))
        onMonitorSettingChange?(.refreshInterval(refreshInterval))
    }
    /// Popover look (`AppAppearance` raw value); the menu bar icon always follows macOS.
    @ObservationIgnored
    @AppStorage(AppAppearance.key) var appearanceRaw: String = AppAppearance.system.rawValue
    private var appearanceTick = 0

    var appearance: AppAppearance {
        get { _ = appearanceTick; return AppAppearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue; appearanceTick += 1 }
    }

    @ObservationIgnored
    @AppStorage(AppBackground.key) var backgroundRaw: String = AppBackground.system.rawValue
    private var backgroundTick = 0

    var background: AppBackground {
        get { _ = backgroundTick; return AppBackground(rawValue: backgroundRaw) ?? .system }
        set { backgroundRaw = newValue.rawValue; backgroundTick += 1 }
    }

    var systemReducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    var usesSolidBackground: Bool { background.isSolid(reduceTransparency: systemReducesTransparency) }
    @ObservationIgnored private var transparencyObserver: NSObjectProtocol?

    func watchSystemTransparency() {
        guard transparencyObserver == nil else { return }
        systemReducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemReducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    }

    deinit {
        if let transparencyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver)
        }
    }

    /// macOS dark mode, kept current by `watchSystemAppearance`.
    var systemIsDark = AppAppearance.systemIsDark

    var isDark: Bool { appearance == .dark || (appearance == .system && systemIsDark) }

    func watchSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemIsDark = AppAppearance.systemIsDark
        }
    }
    @ObservationIgnored
    @AppStorage("menuBarProvider") var menuBarProvider: String = "all" {
        didSet {
            if oldValue != menuBarProvider { onMonitorSettingChange?(.menuBarProvider(menuBarProvider)) }
        }
    }
    /// What the menu bar shows next to the cloud (`MenuBarIndicator` raw value).
    @ObservationIgnored
    @AppStorage("menuBarIndicator") var menuBarIndicatorRaw: String = MenuBarIndicator.status.rawValue
    /// Subscription read by the 5h modes (`UsageAccount.id`); empty picks the first with a 5h window.
    @ObservationIgnored
    @AppStorage("menuBarAccount") var menuBarAccount: String = ""
    /// Weekly percent from which the alert mode shows the busiest subscription.
    @ObservationIgnored
    @AppStorage("menuBarAlertThreshold") var menuBarAlertThreshold: Double = 70
    /// Off: the usage indicators show without the cloud (the status label always keeps it).
    @ObservationIgnored
    @AppStorage("menuBarCloud") var menuBarCloud: Bool = true
    /// Mini gauges followed by their percentage.
    @ObservationIgnored
    @AppStorage("menuBarGaugePercent") var menuBarGaugePercent: Bool = false
    private var menuBarTick = 0

    var menuBarShowsCloud: Bool {
        get { _ = menuBarTick; return menuBarCloud }
        set { menuBarCloud = newValue; menuBarTick += 1 }
    }

    var menuBarGaugeNumbers: Bool {
        get { _ = menuBarTick; return menuBarGaugePercent }
        set { menuBarGaugePercent = newValue; menuBarTick += 1 }
    }

    var menuBarIndicator: MenuBarIndicator {
        get { _ = menuBarTick; return MenuBarIndicator(rawValue: menuBarIndicatorRaw) ?? .status }
        set { menuBarIndicatorRaw = newValue.rawValue; menuBarTick += 1 }
    }

    var menuBarAccountID: UUID? {
        get { _ = menuBarTick; return UUID(uuidString: menuBarAccount) }
        set { menuBarAccount = newValue?.uuidString ?? ""; menuBarTick += 1 }
    }

    var menuBarThreshold: Double {
        get { _ = menuBarTick; return menuBarAlertThreshold }
        set { menuBarAlertThreshold = newValue; menuBarTick += 1 }
    }
    @ObservationIgnored
    @AppStorage("disabledProviders") var disabledProviders: String = "" {
        didSet {
            if oldValue != disabledProviders { onMonitorSettingChange?(.disabledProviders(disabledProviderIDs)) }
        }
    }
    /// Triggers SwiftUI re-render when disabled providers change
    private var disabledProvidersTick = 0
    @ObservationIgnored
    @AppStorage("providerOrder") var providerOrder: String = ""
    @ObservationIgnored
    @AppStorage("watchedComponents") var watchedComponents: String = ""
    private var watchedComponentsTick = 0
    @ObservationIgnored
    @AppStorage("hiddenUsage") var hiddenUsage: String = ""
    @ObservationIgnored
    @AppStorage("usageGroups") var usageGroupsJSON: String = ""
    private var usageGroupsTick = 0
    /// SSH hosts whose Codex usage joins the breakdown, as JSON `[RemoteUsage.Host]`.
    @ObservationIgnored
    @AppStorage("usageSSHHosts") var usageSSHHosts: String = ""
    /// Former comma-separated list of aliases, migrated on first read.
    @ObservationIgnored
    @AppStorage("usageRemoteHosts") var legacyUsageRemoteHosts: String = ""
    private var remoteHostsTick = 0

    var remoteHosts: [RemoteUsage.Host] {
        get {
            _ = remoteHostsTick
            if let hosts = try? JSONDecoder().decode([RemoteUsage.Host].self, from: Data(usageSSHHosts.utf8)) {
                return hosts
            }
            var seen = Set<String>()
            return legacyUsageRemoteHosts.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { RemoteUsage.Host(alias: $0) }
        }
        set {
            usageSSHHosts = (try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? ""
            legacyUsageRemoteHosts = ""
            remoteHostsTick += 1
        }
    }

    // MARK: - Servers

    /// Servers checked over SSH, as JSON `[ServerMonitor]`.
    @ObservationIgnored
    @AppStorage("monitorServers") var monitorServersJSON: String = ""
    @ObservationIgnored
    @AppStorage("serverInterval") var serverInterval: TimeInterval = 300
    private var monitorsTick = 0

    var servers: [ServerMonitor] {
        get { _ = monitorsTick; return (try? JSONDecoder().decode([ServerMonitor].self, from: Data(monitorServersJSON.utf8))) ?? [] }
        set {
            monitorServersJSON = (try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? ""
            monitorsTick += 1
        }
    }

    var serverCheckInterval: TimeInterval {
        get { _ = monitorsTick; return serverInterval }
        set { serverInterval = newValue; monitorsTick += 1 }
    }

    static let serverIntervalOptions: [(label: String, value: TimeInterval)] = [
        ("1 min", 60),
        ("2 min", 120),
        ("5 min", 300),
        ("10 min", 600),
        ("15 min", 900),
    ]

    var launchAtLogin: Bool {
        get {
            _ = launchAtLoginTick
            return SMAppService.mainApp.status == .enabled
        }
        set {
            setLaunchAtLogin(newValue)
        }
    }

    func reconcileLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        if launchAtLoginPreference, status == .notRegistered || status == .notFound {
            setLaunchAtLogin(true)
        } else {
            updateLaunchAtLoginStatusMessage()
        }
    }

    func refreshLaunchAtLoginStatus() {
        updateLaunchAtLoginStatusMessage()
        launchAtLoginTick += 1
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                launchAtLoginPreference = true
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginPreference = false
            }
        } catch {
            launchAtLoginStatusMessage = "Launch at login could not be updated: \(error.localizedDescription)"
            if enabled {
                launchAtLoginPreference = false
            }
            launchAtLoginTick += 1
            return
        }

        updateLaunchAtLoginStatusMessage()
        launchAtLoginTick += 1
    }

    private func updateLaunchAtLoginStatusMessage() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginStatusMessage = nil
        case .notRegistered:
            launchAtLoginStatusMessage = launchAtLoginPreference
                ? "Launch at login is not registered with macOS."
                : nil
        case .requiresApproval:
            launchAtLoginStatusMessage = "Approve LLM Status in System Settings > General > Login Items."
        case .notFound:
            launchAtLoginStatusMessage = "macOS could not find this app bundle for login items."
        @unknown default:
            launchAtLoginStatusMessage = "macOS returned an unknown login item status."
        }
    }

    /// IDs of providers the user has disabled
    var disabledProviderIDs: Set<String> {
        get {
            Set(disabledProviders.split(separator: ",").map(String.init))
        }
        set {
            disabledProviders = newValue.sorted().joined(separator: ",")
        }
    }

    func isProviderEnabled(_ id: String) -> Bool {
        _ = disabledProvidersTick // read to subscribe to changes
        return !disabledProviderIDs.contains(id)
    }

    func toggleProvider(_ id: String) {
        var ids = disabledProviderIDs
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        disabledProviderIDs = ids
        disabledProvidersTick += 1 // trigger re-render
    }

    /// Ordered list of provider IDs (persisted)
    var providerOrderIDs: [String] {
        get {
            let ids = providerOrder.split(separator: ",").map(String.init)
            return ids.isEmpty ? [] : ids
        }
        set {
            providerOrder = newValue.joined(separator: ",")
        }
    }

    // MARK: - Subscription usage

    /// Subscriptions shown, by group. Before groups existed, only this Mac's logins were shown,
    /// each hideable: those settings become the first group.
    /// Writes the migrated groups once, so account ids stay the same from one read to the next.
    func materializeUsageGroups() {
        if (try? JSONDecoder().decode([UsageGroup].self, from: Data(usageGroupsJSON.utf8))) == nil {
            usageGroups = usageGroups
        }
    }

    var usageGroups: [UsageGroup] {
        get {
            _ = usageGroupsTick
            if let groups = try? JSONDecoder().decode([UsageGroup].self, from: Data(usageGroupsJSON.utf8)) {
                return groups
            }
            let hidden = Set(hiddenUsage.split(separator: ",").compactMap { SubscriptionUsage.Kind(rawValue: String($0)) })
            return UsageGroup.defaults(hidden: hidden)
        }
        set {
            usageGroupsJSON = (try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? ""
            usageGroupsTick += 1
        }
    }

    // MARK: - Watched components per provider

    /// Get the watched component name for a provider ("all" = overall status)
    func watchedComponent(for providerID: String) -> String {
        _ = watchedComponentsTick
        let map = parseWatchedComponents()
        return map[providerID] ?? "all"
    }

    /// Set the watched component for a provider
    func setWatchedComponent(_ componentName: String, for providerID: String) {
        var map = parseWatchedComponents()
        if componentName == "all" {
            map.removeValue(forKey: providerID)
        } else {
            map[providerID] = componentName
        }
        watchedComponents = map.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
        watchedComponentsTick += 1
    }

    private func parseWatchedComponents() -> [String: String] {
        guard !watchedComponents.isEmpty else { return [:] }
        var map: [String: String] = [:]
        for entry in watchedComponents.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                map[String(parts[0])] = String(parts[1])
            }
        }
        return map
    }

    /// Human-readable interval options for the picker.
    static let intervalOptions: [(label: String, value: TimeInterval)] = [
        ("1 min", 60),
        ("2 min", 120),
        ("5 min", 300),
        ("10 min", 600),
    ]
}

/// Light, dark, or the macOS setting, for the popover and the app's alerts.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Same as macOS"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Always explicit: a popover left without one takes the menu bar's look, not the system's.
    static func nsAppearance(dark: Bool) -> NSAppearance? {
        NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// The saved choice resolved to light or dark, for views that do not hold `AppSettings` (alerts).
    static var currentIsDark: Bool {
        let saved = AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        return saved == .dark || (saved == .system && systemIsDark)
    }
}

/// Settings that need to reach the running monitor as soon as they are saved.
enum MonitorSettingChange: Equatable {
    case refreshInterval(TimeInterval)
    case notificationsEnabled(Bool)
    case menuBarProvider(String)
    case disabledProviders(Set<String>)
}

/// The popover's native material, or an opaque background.
enum AppBackground: String, CaseIterable, Identifiable {
    case system, translucent, solid

    static let key = "background"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Same as macOS"
        case .translucent: "Translucent"
        case .solid: "Solid"
        }
    }

    func isSolid(reduceTransparency: Bool) -> Bool {
        self == .solid || (self == .system && reduceTransparency)
    }
}
