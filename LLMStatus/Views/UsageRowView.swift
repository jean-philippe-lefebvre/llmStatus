import SwiftUI

/// Weekly limit gauge for one subscription, with the shorter window as a secondary figure.
struct UsageRowView: View {
    let usage: SubscriptionUsage
    /// Offered on an expired token this Mac can renew (local Claude login).
    var renew: (() -> Void)?
    var renewing = false
    /// Offered when this Mac's Codex login has free resets: uses the one chosen, after confirmation.
    var useReset: ((CodexResets.Credit) -> Void)?
    var resetting = false
    var resetError: String?
    @State private var isExpanded: Bool

    init(usage: SubscriptionUsage, startExpanded: Bool = false, renew: (() -> Void)? = nil, renewing: Bool = false,
         useReset: ((CodexResets.Credit) -> Void)? = nil, resetting: Bool = false, resetError: String? = nil) {
        self.usage = usage
        self.renew = renew
        self.renewing = renewing
        self.useReset = useReset
        self.resetting = resetting
        self.resetError = resetError
        _isExpanded = State(initialValue: startExpanded)
    }

    private var hasBreakdown: Bool { !usage.breakdown.isEmpty && usage.weekly != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(usage.displayName)
                    .font(.subheadline.weight(.semibold))
                if let plan = usage.plan {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let weekly = usage.weekly {
                    Text("\(Int(weekly.percent.rounded()))% \(weekly.label)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Self.color(for: weekly.percent))
                }

                if hasBreakdown {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }

                Button {
                    NSWorkspace.shared.open(usage.kind.dashboardURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Open usage page")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasBreakdown else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            if let weekly = usage.weekly {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Self.color(for: weekly.percent))
                            .frame(width: proxy.size.width * min(max(weekly.percent, 0), 100) / 100)
                    }
                }
                .frame(height: 5)
            }

            HStack(spacing: 8) {
                if let resetsAt = usage.weekly?.resetsAt {
                    Text("Resets \(Self.resetLabel(resetsAt))")
                }
                Spacer()
                if let session = usage.session {
                    // The short window resets within hours: a countdown, kept current.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.sessionLabel(session, now: context.date))
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // On its own line: the error, its last attempt and the age of the limits still shown.
            if let error = usage.error {
                Label(Self.errorLine(error, keptFrom: usage.weekly == nil ? nil : usage.fetchedAt, triedAt: usage.checkedAt),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if usage.tokenExpired, let renew {
                HStack(spacing: 6) {
                    Button(renewing ? "Renewing…" : "Renew with Claude Code", action: renew)
                        .controlSize(.small)
                        .disabled(renewing)
                    if renewing {
                        ProgressView().controlSize(.mini)
                    }
                }
                .help("Sends one short request with Claude Code (Haiku) so it renews its login.")
            }

            if let useReset, let credits = usage.resetCredits, !credits.isEmpty || resetError != nil {
                resetLine(credits, use: useReset)
            }

            if isExpanded, let weekly = usage.weekly {
                breakdown(weeklyPercent: weekly.percent)
            }
        }
    }

    private func resetLine(_ credits: [CodexResets.Credit], use: @escaping (CodexResets.Credit) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if !credits.isEmpty {
                    Menu {
                        ForEach(credits) { credit in
                            Button("\(credit.title) · \(Self.expiryLabel(credit.expiresAt))") {
                                if Self.confirmReset(credit, usage: usage) { use(credit) }
                            }
                        }
                    } label: {
                        Text(credits.count == 1 ? "1 reset available" : "\(credits.count) resets available")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(resetting)
                    .help("Use a free reset to restore your Codex 5h and weekly limits")
                }
                if resetting {
                    Text("Resetting…").foregroundStyle(.secondary)
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if let soonest = credits.first?.expiresAt, soonest.timeIntervalSinceNow < 2 * 24 * 3600 {
                    Text("Next expires \(Self.expiryLabel(soonest).replacingOccurrences(of: "expires ", with: ""))")
                        .foregroundStyle(.secondary)
                }
            }
            if let resetError {
                Label(resetError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption2)
    }

    static func expiryLabel(_ date: Date?) -> String {
        guard let date else { return "no expiry" }
        return "expires \(resetLabel(date))"
    }

    /// A reset cannot be undone: always ask, and say how much of it would go unused.
    static func confirmReset(_ credit: CodexResets.Credit, usage: SubscriptionUsage) -> Bool {
        let alert = NSAlert()
        alert.window.appearance = AppAppearance.nsAppearance(dark: AppAppearance.currentIsDark)
        alert.messageText = "Use a Codex reset?"
        var text = "This restores your Codex 5-hour and weekly limits now. It cannot be undone."
        if let weekly = usage.weekly {
            text += "\n\nWeekly usage is \(Int(weekly.percent.rounded()))%"
            if let session = usage.session { text += ", 5h usage is \(Int(session.percent.rounded()))%" }
            text += ": that is what the reset gives back."
        }
        text += "\n\n\(credit.title), \(expiryLabel(credit.expiresAt))."
        alert.informativeText = text
        alert.addButton(withTitle: "Use reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apps (or SSH hosts, then their apps), then projects, each with its estimated part of the weekly percentage.
    private func breakdown(weeklyPercent: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(usage.breakdown) { top in
                shareRow(top.name, share: top.share, weeklyPercent: weeklyPercent)
                    .font(.caption.weight(.medium))
                ForEach(top.children) { child in
                    shareRow(child.name, share: child.share, weeklyPercent: weeklyPercent)
                        .font(child.children.isEmpty ? .caption2 : .caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                    ForEach(child.children) { project in
                        shareRow(project.name, share: project.share, weeklyPercent: weeklyPercent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 24)
                    }
                }
            }
            ForEach(usage.breakdownErrors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Estimated from logs (tokens). \(usage.kind.breakdownCaveat)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func shareRow(_ name: String, share: Double, weeklyPercent: Double) -> some View {
        HStack {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(Self.percentLabel(share * weeklyPercent))
                .monospacedDigit()
            Text(share < 0.005 ? "(<1%)" : "(\(Int((share * 100).rounded()))%)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// One decimal below 10 % so small consumers are not all "0%"; "<0.1%" rather than a false zero.
    static func percentLabel(_ value: Double) -> String {
        switch value {
        case ..<0.05: "<0.1%"
        case ..<10: String(format: "%.1f%%", value)
        default: "\(Int(value.rounded()))%"
        }
    }

    /// The error, when it was last tried, and when the limits still shown were read.
    static func errorLine(_ error: String, keptFrom date: Date?, triedAt: Date? = nil) -> String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        var line = error
        if let triedAt { line += " · tried \(time(triedAt))" }
        if let date { line += ", data from \(time(date))" }
        return line
    }

    /// "5h: 5% · resets in 3h 45m". An unused window has no reset time yet: its clock starts
    /// with the next message. No countdown once the reset time has passed.
    static func sessionLabel(_ window: SubscriptionUsage.Window, now: Date = Date()) -> String {
        let used = "\(window.label): \(Int(window.percent.rounded()))%"
        guard let resetsAt = window.resetsAt else { return window.percent == 0 ? "\(used) · starts on next use" : used }
        guard let left = MenuBarContent.countdown(window, now: now), resetsAt > now else { return used }
        return "\(used) · resets in \(left)"
    }

    static func color(for percent: Double) -> Color {
        switch percent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }

    /// "Fri 19:00" within the week, otherwise a short date.
    static func resetLabel(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(
            date.timeIntervalSince(now) < 6 * 24 * 3600 ? "EEE jj:mm" : "MMM d jj:mm"
        )
        return formatter.string(from: date)
    }
}
