import AppKit
import SwiftUI

/// Settings tab for the menu bar item: the selected template with its options, then every
/// template drawn with the current data, ready to pick.
struct MenuBarSettingsSection: View {
    @Bindable var settings: AppSettings
    var monitor: StatusMonitor
    /// Enabled providers, in the user's order, for the status source.
    let providers: [ServiceProvider]

    var body: some View {
        let accounts = MenuBarContent.accounts(monitor.usage.sections, issue: monitor.serviceIssue)
        let mode = settings.menuBarIndicator

        Section("Menu bar") {
            HStack {
                Text(mode.title)
                Spacer()
                preview(mode, accounts: accounts)
            }
            Picker("Status from", selection: $settings.menuBarProvider) {
                Text("All providers").tag("all")
                ForEach(providers) { Text($0.name).tag($0.id) }
            }
            if mode != .status {
                Toggle("Show the cloud with usage", isOn: Binding(
                    get: { settings.menuBarShowsCloud },
                    set: { settings.menuBarShowsCloud = $0 }
                ))
            }
            if mode == .gauges {
                Toggle("Percent next to each gauge", isOn: Binding(
                    get: { settings.menuBarGaugeNumbers },
                    set: { settings.menuBarGaugeNumbers = $0 }
                ))
                Toggle("5h gauge before each weekly one", isOn: Binding(
                    get: { settings.showsSessionBar },
                    set: { settings.showsSessionBar = $0 }
                ))
            }
            if mode.needsAccount {
                Picker("Subscription", selection: Binding(
                    get: { settings.menuBarAccountID },
                    set: { settings.menuBarAccountID = $0 }
                )) {
                    Text("First with a 5h window").tag(UUID?.none)
                    ForEach(monitor.usage.groups) { group in
                        ForEach(group.accounts.filter(\.enabled)) { account in
                            Text("\(group.name) · \(account.name)").tag(UUID?.some(account.id))
                        }
                    }
                }
            }
            if mode == .alert {
                Picker("Show usage from", selection: Binding(
                    get: { settings.menuBarThreshold },
                    set: { settings.menuBarThreshold = $0 }
                )) {
                    ForEach([50.0, 60, 70, 80, 90], id: \.self) { Text("\(Int($0))% weekly").tag($0) }
                }
            }
        }

        Section {
            ForEach(MenuBarIndicator.allCases) { template in
                HStack {
                    Image(systemName: template == mode ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(template == mode ? Color.accentColor : Color.secondary)
                    Text(template.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer()
                    preview(template, accounts: accounts)
                }
                .contentShape(Rectangle())
                .onTapGesture { settings.menuBarIndicator = template }
            }
        } header: {
            Text("Templates")
        } footer: {
            Text("Drawn with your current usage. The cloud's color is the providers' status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One template as the menu bar draws it, on a menu-bar-like strip.
    private func preview(_ template: MenuBarIndicator, accounts: [MenuBarAccount]) -> some View {
        let status = monitor.menuBarStatus(for: settings.menuBarProvider)
        let selected = template == settings.menuBarIndicator
        return MenuBarPreview(
            cloudColor: status.nsColor,
            label: monitor.menuBarLabel(for: settings.menuBarProvider),
            pieces: MenuBarContent.pieces(template, accounts: accounts, chosen: settings.menuBarAccountID,
                                          threshold: settings.menuBarThreshold, sessionBars: settings.showsSessionBar),
            // Other templates show with the defaults; the selected one with its options.
            showCloud: selected ? settings.menuBarShowsCloud : true,
            gaugeNumbers: selected && settings.menuBarGaugeNumbers
        )
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
    }
}

/// The real menu bar button drawing (`StatusBarController.draw`), for previews.
struct MenuBarPreview: NSViewRepresentable {
    let cloudColor: NSColor
    let label: String
    let pieces: [MenuBarPiece]?
    let showCloud: Bool
    let gaugeNumbers: Bool

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.refusesFirstResponder = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        StatusBarController.draw(on: button, cloud: StatusBarController.tintedMenuBarIcon(cloudColor), label: label,
                                 pieces: pieces, showCloud: showCloud, gaugeNumbers: gaugeNumbers)
        button.invalidateIntrinsicContentSize()
    }
}
