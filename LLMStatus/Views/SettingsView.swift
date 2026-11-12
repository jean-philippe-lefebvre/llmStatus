import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var monitor: StatusMonitor
    @State private var orderedProviders: [ServiceProvider] = []
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable {
        case general = "General"
        case status = "Status"
        case usage = "Usage"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Form {
                switch tab {
                case .general:
                    Section("App") {
                        Picker("Refresh interval", selection: $settings.refreshInterval) {
                            ForEach(AppSettings.intervalOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }

                        Toggle("Launch at login", isOn: $settings.launchAtLogin)

                        if let message = settings.launchAtLoginStatusMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Notifications", isOn: $settings.notificationsEnabled)

                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                        }

                        Picker("Background", selection: $settings.background) {
                            ForEach(AppBackground.allCases) { Text($0.label).tag($0) }
                        }
                    }

                    MenuBarSettingsSection(settings: settings, monitor: monitor,
                                           providers: orderedProviders.filter { settings.isProviderEnabled($0.id) })

                    Section {
                        LabeledContent("Version") {
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                                .foregroundStyle(.secondary)
                        }
                        Button("Open logs folder") {
                            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Library/Logs/LLMStatus")
                            NSWorkspace.shared.open(logsDir)
                        }
                    }
                case .status:
                    // Providers — drag & drop reorder + enable/disable
                    Section("Providers") {
                        List {
                            ForEach(orderedProviders) { provider in
                                HStack {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption)

                                    Toggle(provider.name, isOn: Binding(
                                        get: { settings.isProviderEnabled(provider.id) },
                                        set: { _ in
                                            settings.toggleProvider(provider.id)
                                        }
                                    ))
                                }
                                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                            }
                            .onMove { from, to in
                                orderedProviders.move(fromOffsets: from, toOffset: to)
                                let ids = orderedProviders.map(\.id)
                                settings.providerOrderIDs = ids
                                monitor.reorderProviders(orderedIDs: ids)
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 26)
                        .frame(height: CGFloat(orderedProviders.count) * 26)
                        .scrollDisabled(true)
                    }

                    // Watched component per provider
                    Section("Focus component") {
                        ForEach(orderedProviders.filter { settings.isProviderEnabled($0.id) && !$0.components.isEmpty }) { provider in
                            Picker(provider.shortName, selection: Binding(
                                get: { settings.watchedComponent(for: provider.id) },
                                set: { newValue in
                                    settings.setWatchedComponent(newValue, for: provider.id)
                                    monitor.watchedComponentMap = buildWatchedMap()
                                }
                            )) {
                                Text("All").tag("all")
                                ForEach(allComponentNames(for: provider), id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    MonitorsSettingsSection(settings: settings, infra: monitor.infra)
                case .usage:
                    // Subscriptions shown, by group (this Mac's logins and logins on SSH hosts)
                    UsageAccountsSection(settings: settings, usage: monitor.usage)

                    RemoteHostsSection(settings: settings, usage: monitor.usage)

                    Section {
                        Toggle("5h limit as a second bar", isOn: Binding(
                            get: { settings.showsSessionBar },
                            set: { settings.showsSessionBar = $0 }
                        ))
                    } footer: {
                        Text("A thinner teal bar above the weekly one, for subscriptions with a 5-hour window. The menu bar mini gauges show it too, 5h first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section {
                        Toggle("Renew Claude logins automatically", isOn: $settings.autoRenewClaude)
                    } footer: {
                        Text("When a Claude Code login expires (about every 8 hours if you work in the Claude app), it is renewed through the claude CLI, here or on its SSH host. It tries /usage first, which sends no model request.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            // The grouped form paints its own opaque backdrop: hide it so a translucent popover stays translucent.
            .scrollContentBackground(settings.usesSolidBackground ? .visible : .hidden)
        }
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            orderedProviders = monitor.orderedProviders(by: settings.providerOrderIDs)
            monitor.watchedComponentMap = buildWatchedMap()
        }
    }

    /// Flat list of component names (groups + children) for a provider
    private func allComponentNames(for provider: ServiceProvider) -> [String] {
        var names: [String] = []
        for component in provider.components {
            names.append(component.name)
            for child in component.children {
                names.append(child.name)
            }
        }
        return names
    }

    /// Build the watched component map from settings
    private func buildWatchedMap() -> [String: String] {
        var map: [String: String] = [:]
        for provider in orderedProviders {
            let watched = settings.watchedComponent(for: provider.id)
            if watched != "all" {
                map[provider.id] = watched
            }
        }
        return map
    }
}
