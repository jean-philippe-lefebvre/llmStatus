import Foundation

/// What the menu bar item shows next to the cloud, whose color stays the providers' status.
enum MenuBarIndicator: String, CaseIterable, Identifiable {
    case status, busiest, alert, session, weeklyAndSession, gauges, allAccounts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "Status only"
        case .busiest: "Busiest"
        case .alert: "Alert past a threshold"
        case .session: "5h countdown"
        case .weeklyAndSession: "Weekly and 5h"
        case .gauges: "Mini gauges"
        case .allAccounts: "All as text"
        }
    }

    /// Modes that read one subscription picked in Settings.
    var needsAccount: Bool { self == .session || self == .weeklyAndSession }
}

/// One subscription as the menu bar sees it.
struct MenuBarAccount: Equatable {
    var id: UUID?
    var name: String
    /// Short label for "every subscription as text", e.g. "C", "X", "I".
    var short: String
    var weekly: SubscriptionUsage.Window?
    var session: SubscriptionUsage.Window?
}

/// Pieces of the menu bar item after the cloud. Percent colors follow the usage gauges.
enum MenuBarPiece: Equatable {
    case text(String)
    /// A percentage, colored like its gauge.
    case percent(String, Double)
    /// Dimmed separator.
    case separator(String)
    /// Vertical gauges (0...100), one group per subscription: 5h then weekly when the 5h one is
    /// shown (two values), weekly alone otherwise.
    case gauges([[Double]])
}

enum MenuBarContent {
    /// The subscriptions shown in the popover, with short labels: the kind's letter (C, X) in the
    /// first group, the group's initial in the others ("I" for Index), plus the kind's letter
    /// when that group has both kinds.
    static func accounts(_ sections: [(group: UsageGroup, usages: [SubscriptionUsage])]) -> [MenuBarAccount] {
        sections.enumerated().flatMap { index, section in
            let kinds = Set(section.usages.map(\.kind))
            return section.usages.map { usage in
                let kindLetter = usage.kind == .claude ? "C" : "X"
                let groupLetter = section.group.name.first.map { String($0).uppercased() } ?? ""
                let short = index == 0 ? kindLetter : groupLetter + (kinds.count > 1 ? kindLetter : "")
                return MenuBarAccount(id: usage.accountID, name: usage.displayName, short: short,
                                      weekly: usage.weekly, session: usage.session)
            }
        }
    }

    /// Nil when the mode has nothing to add: the item then shows the status label.
    static func pieces(_ mode: MenuBarIndicator, accounts: [MenuBarAccount], chosen: UUID?,
                       threshold: Double, sessionBars: Bool = false, now: Date = Date()) -> [MenuBarPiece]? {
        let measured = accounts.filter { $0.weekly != nil }
        let busiest = measured.max { $0.weekly!.percent < $1.weekly!.percent }
        let picked = accounts.first { $0.id == chosen } ?? accounts.first { $0.session != nil } ?? accounts.first
        switch mode {
        case .status:
            return nil
        case .busiest:
            return busiest.map { [.percent(percent($0.weekly!), $0.weekly!.percent)] }
        case .alert:
            guard let busiest, busiest.weekly!.percent >= threshold else { return nil }
            return [.percent(percent(busiest.weekly!), busiest.weekly!.percent)]
        case .session:
            guard let session = picked?.session else { return picked?.weekly.map { [.percent(percent($0), $0.percent)] } }
            var pieces: [MenuBarPiece] = [.percent(percent(session), session.percent)]
            if let left = countdown(session, now: now) { pieces += [.separator(" · "), .text(left)] }
            return pieces
        case .weeklyAndSession:
            guard let weekly = picked?.weekly else { return nil }
            var pieces: [MenuBarPiece] = [.percent(percent(weekly), weekly.percent)]
            if let session = picked?.session { pieces += [.separator(" | "), .percent(percent(session), session.percent)] }
            return pieces
        case .gauges:
            return measured.isEmpty ? nil : [.gauges(measured.map { account in
                (sessionBars ? account.session.map { [$0.percent] } ?? [] : []) + [account.weekly!.percent]
            })]
        case .allAccounts:
            guard !measured.isEmpty else { return nil }
            return measured.enumerated().flatMap { index, account -> [MenuBarPiece] in
                let value = account.weekly!.percent
                let item: [MenuBarPiece] = [.text("\(account.short) "), .percent("\(Int(value.rounded()))", value)]
                return index == 0 ? item : [.separator(" · ")] + item
            }
        }
    }

    /// The account the busiest and alert modes point at, for the tooltip.
    static func busiestName(_ accounts: [MenuBarAccount]) -> String? {
        accounts.filter { $0.weekly != nil }.max { $0.weekly!.percent < $1.weekly!.percent }?.name
    }

    private static func percent(_ window: SubscriptionUsage.Window) -> String {
        "\(Int(window.percent.rounded()))%"
    }

    /// "50m", "3h 45m"; nil without a future reset.
    static func countdown(_ window: SubscriptionUsage.Window, now: Date) -> String? {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        let minutes = Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
