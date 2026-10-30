import AppKit
import SwiftUI

extension Notification.Name {
    static let showSettings = Notification.Name("showSettings")
    /// Posted right before the popover opens: its scroll areas size themselves to their content again.
    static let popoverWillOpen = Notification.Name("popoverWillOpen")
}

/// Manages the NSStatusItem with left-click (popover) and right-click (context menu).
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private let popover = NSPopover()
    private var monitor: StatusMonitor
    private var settings: AppSettings
    private var network: NetworkMonitor
    private var iconTimer: Timer?

    init(monitor: StatusMonitor, settings: AppSettings, network: NetworkMonitor) {
        self.monitor = monitor
        self.settings = settings
        self.network = network
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        setupPopover()
        setupButton()
        updateIcon()

        // Poll icon state — lightweight since it only redraws on change
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    /// Always explicit (left unset, the popover copies the menu bar's look), and on the open
    /// window and hosted view too, which otherwise keep the look they opened with.
    private static func apply(dark: Bool, to popover: NSPopover) {
        let look = AppAppearance.nsAppearance(dark: dark)
        popover.appearance = look
        popover.contentViewController?.view.appearance = look
        popover.contentViewController?.view.window?.appearance = look
    }

    private func setupPopover() {
        let m = monitor
        let s = settings
        let n = network
        let popover = popover
        let view = StatusPopoverView(monitor: m, settings: s, network: n)
            .onChange(of: s.refreshInterval) { _, newInterval in
                m.startPolling(interval: newInterval)
            }
            .onChange(of: s.notificationsEnabled) { _, enabled in
                m.notificationsEnabled = enabled
                m.infra.notificationsEnabled = enabled
            }
            .onChange(of: s.menuBarProvider) { _, providerID in
                m.notifyProviderID = providerID
            }
            .onChange(of: s.disabledProviders) { _, _ in
                m.disabledProviderIDs = s.disabledProviderIDs
            }
        let themed = ThemedRoot(settings: s, content: view) { dark in
            Self.apply(dark: dark, to: popover)
        }

        // The popover takes the size of its content (see FittingScrollView) instead of a fixed height.
        let hosting = NSHostingController(rootView: themed)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        Self.apply(dark: s.isDark, to: popover)
        s.watchSystemAppearance()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            Task { await monitor.usage.refreshIfStale() }
            NotificationCenter.default.post(name: .popoverWillOpen, object: nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Self.apply(dark: settings.isDark, to: popover)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(settingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LLM Status", action: #selector(quitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset so left-click still opens popover
        statusItem.menu = nil
    }

    @objc private func refreshAction() {
        Task { await monitor.forceRefresh() }
    }

    @objc private func settingsAction() {
        // Open popover then notify it to show settings
        if !popover.isShown, let button = statusItem.button {
            NotificationCenter.default.post(name: .popoverWillOpen, object: nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Self.apply(dark: settings.isDark, to: popover)
            popover.contentViewController?.view.window?.makeKey()
        }
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Icon

    /// Everything the item shows; redrawn only when it changes.
    private var lastIconKey: String?

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let status = monitor.menuBarStatus(for: settings.menuBarProvider)
        let label = monitor.menuBarLabel(for: settings.menuBarProvider)
        let accounts = MenuBarContent.accounts(monitor.usage.sections)
        let mode = settings.menuBarIndicator
        let pieces = MenuBarContent.pieces(mode, accounts: accounts, chosen: settings.menuBarAccountID,
                                           threshold: settings.menuBarThreshold)

        let key = "\(status)|\(label)|\(String(describing: pieces))|\(settings.menuBarShowsCloud)|\(settings.menuBarGaugeNumbers)"
        guard key != lastIconKey else { return }
        lastIconKey = key

        Self.draw(on: button, cloud: Self.tintedMenuBarIcon(status.nsColor), label: label, pieces: pieces,
                  // A provider issue brings the cloud back: its color is the only status signal.
                  showCloud: settings.menuBarShowsCloud || status.severity >= 2, gaugeNumbers: settings.menuBarGaugeNumbers)
        button.toolTip = pieces != nil && (mode == .busiest || mode == .alert)
            ? MenuBarContent.busiestName(accounts).map { "Busiest: \($0)" } : "LLM Status"
    }

    /// Puts the cloud, then the status label or the indicator's pieces, on the menu bar button.
    /// `showCloud` false drops the cloud when usage is shown; the status label always keeps it.
    static func draw(on button: NSButton, cloud: NSImage, label: String, pieces: [MenuBarPiece]?,
                     showCloud: Bool = true, gaugeNumbers: Bool = false) {
        guard let pieces else {
            button.image = cloud
            button.attributedTitle = NSAttributedString(string: " \(label)")
            button.imagePosition = .imageLeading
            return
        }
        var gauges: [Double] = []
        let title = NSMutableAttributedString(string: showCloud ? " " : "")
        let font = NSFont.menuBarFont(ofSize: 0)
        for piece in pieces {
            switch piece {
            case .text(let text):
                title.append(NSAttributedString(string: text, attributes: [.font: font]))
            case .separator(let text):
                title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            case .percent(let text, let value):
                title.append(NSAttributedString(string: text, attributes: percentAttributes(value, font: font)))
            case .gauges(let values):
                gauges = values
            }
        }
        if !gauges.isEmpty {
            button.image = withGauges(showCloud ? cloud : nil, gauges, numbers: gaugeNumbers, in: button)
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            button.image = showCloud ? cloud : nil
            button.attributedTitle = title
            button.imagePosition = showCloud ? .imageLeading : .noImage
        }
    }

    /// Under the warning level a number keeps the menu bar's own color, like the usage gauges.
    private static func percentAttributes(_ value: Double, font: NSFont) -> [NSAttributedString.Key: Any] {
        let color: NSColor = value >= 90 ? .systemRed : value >= 70 ? .systemOrange : .labelColor
        return [.font: font, .foregroundColor: color]
    }

    /// The cloud (if any), then one thin vertical gauge per subscription, each optionally followed
    /// by its percentage.
    private static func withGauges(_ cloud: NSImage?, _ values: [Double], numbers: Bool, in button: NSButton) -> NSImage {
        let barWidth: CGFloat = 4, barHeight: CGFloat = 14, height: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let labels = values.map { NSAttributedString(string: "\(Int($0.rounded()))", attributes: percentAttributes($0, font: font)) }
        let gap: CGFloat = numbers ? 7 : 2
        let lead = cloud.map { $0.size.width + 5 } ?? 0
        let widths = values.indices.map { barWidth + (numbers ? 3 + ceil(labels[$0].size().width) : 0) }
        let size = NSSize(width: lead + widths.reduce(0, +) + gap * CGFloat(values.count - 1), height: height)
        let image = NSImage(size: size, flipped: false) { [weak button] rect in
            // Label colors follow the menu bar (light or dark), read when the image is drawn.
            let appearance = button?.effectiveAppearance ?? NSAppearance.currentDrawing()
            appearance.performAsCurrentDrawingAppearance {
            cloud?.draw(in: NSRect(x: 0, y: (rect.height - (cloud?.size.height ?? 0)) / 2, width: cloud?.size.width ?? 0, height: cloud?.size.height ?? 0))
            var x = lead
            for (index, value) in values.enumerated() {
                let base = NSRect(x: x, y: (rect.height - barHeight) / 2, width: barWidth, height: barHeight)
                NSColor.labelColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: base, xRadius: 1, yRadius: 1).fill()
                let fill = max(1.5, barHeight * min(max(value, 0), 100) / 100)
                (value >= 90 ? NSColor.systemRed : value >= 70 ? NSColor.systemOrange : NSColor.systemGreen).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: base.minY, width: barWidth, height: fill), xRadius: 1, yRadius: 1).fill()
                if numbers {
                    let label = labels[index]
                    label.draw(at: NSPoint(x: x + barWidth + 3, y: (rect.height - label.size().height) / 2))
                }
                x += widths[index] + gap
            }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func tintedMenuBarIcon(_ tint: NSColor) -> NSImage {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "pdf"),
              let template = NSImage(contentsOf: url) else {
            return fallbackDot(tint)
        }

        let height: CGFloat = 18
        let aspect = template.size.width / template.size.height
        let size = NSSize(width: height * aspect, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func fallbackDot(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Reads the appearance inside a view body, so a change reaches the open popover: the root
/// view built in `setupPopover` is created once and never sees new values.
private struct ThemedRoot<Content: View>: View {
    let settings: AppSettings
    let content: Content
    let apply: (Bool) -> Void

    var body: some View {
        content
            .environment(\.colorScheme, settings.isDark ? .dark : .light)
            // Solid: the popover's glass lets the window behind tint the header (a dark
            // window greys a light header, a bright one lightens a dark header).
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: settings.isDark) { _, dark in apply(dark) }
    }
}
