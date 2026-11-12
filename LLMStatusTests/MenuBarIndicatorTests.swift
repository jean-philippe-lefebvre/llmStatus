import Foundation
import Testing
@testable import LLMStatus

@Suite("Menu bar indicator")
struct MenuBarIndicatorTests {
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    func window(_ percent: Double, resetIn seconds: TimeInterval? = nil, length: Int = 7 * 24 * 3600) -> SubscriptionUsage.Window {
        .init(percent: percent, resetsAt: seconds.map { now.addingTimeInterval($0) }, seconds: length)
    }

    let sample: [MenuBarAccount]

    init() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func window(_ percent: Double, resetIn seconds: TimeInterval? = nil, length: Int = 7 * 24 * 3600) -> SubscriptionUsage.Window {
            .init(percent: percent, resetsAt: seconds.map { now.addingTimeInterval($0) }, seconds: length)
        }
        let personal = UsageGroup(name: "Personal")
        let index = UsageGroup(name: "Index")
        let claude = UUID(), codex = UUID(), work = UUID()
        func usage(_ kind: SubscriptionUsage.Kind, _ id: UUID, _ weekly: Double, session: SubscriptionUsage.Window? = nil) -> SubscriptionUsage {
            SubscriptionUsage(kind: kind, weekly: window(weekly), session: session, accountID: id, title: kind.name)
        }
        sample = MenuBarContent.accounts([
            (personal, [usage(.claude, claude, 45, session: window(5, resetIn: 50 * 60, length: 5 * 3600)), usage(.codex, codex, 0)]),
            (index, [usage(.claude, work, 75, session: window(3, resetIn: 110 * 60, length: 5 * 3600))]),
        ])
    }

    @Test("Short labels: kind letter in the first group, group initial in the others")
    func shortLabels() {
        #expect(sample.map(\.short) == ["C", "X", "I"])
    }

    @Test("Status only, busiest and alert past its threshold")
    func statusBusiestAlert() {
        #expect(MenuBarContent.pieces(.status, accounts: sample, chosen: nil, threshold: 70) == nil)
        #expect(MenuBarContent.pieces(.busiest, accounts: sample, chosen: nil, threshold: 70) == [.percent("75%", 75)])
        #expect(MenuBarContent.pieces(.alert, accounts: sample, chosen: nil, threshold: 70) == [.percent("75%", 75)])
        #expect(MenuBarContent.pieces(.alert, accounts: sample, chosen: nil, threshold: 80) == nil)
        #expect(MenuBarContent.busiestName(sample) == "Claude")
    }

    @Test("5h modes read the chosen subscription, else the first with a 5h window")
    func sessionModes() {
        let work = sample[2].id
        #expect(MenuBarContent.pieces(.session, accounts: sample, chosen: nil, threshold: 70, now: now)
                == [.percent("5%", 5), .separator(" · "), .text("50m")])
        #expect(MenuBarContent.pieces(.session, accounts: sample, chosen: work, threshold: 70, now: now)
                == [.percent("3%", 3), .separator(" · "), .text("1h 50m")])
        #expect(MenuBarContent.pieces(.weeklyAndSession, accounts: sample, chosen: nil, threshold: 70, now: now)
                == [.percent("45%", 45), .separator(" | "), .percent("5%", 5)])
        // A subscription without a 5h window shows its weekly percent.
        #expect(MenuBarContent.pieces(.session, accounts: sample, chosen: sample[1].id, threshold: 70, now: now) == [.percent("0%", 0)])
    }

    @Test("Gauges and text cover every subscription with a weekly limit")
    func everySubscription() {
        #expect(MenuBarContent.pieces(.gauges, accounts: sample, chosen: nil, threshold: 70) == [.gauges([[45], [0], [75]])])
        #expect(MenuBarContent.pieces(.gauges, accounts: sample, chosen: nil, threshold: 70, sessionBars: true)
                == [.gauges([[5, 45], [0], [3, 75]])])
        #expect(MenuBarContent.pieces(.allAccounts, accounts: sample, chosen: nil, threshold: 70) == [
            .text("C "), .percent("45", 45), .separator(" · "), .text("X "), .percent("0", 0),
            .separator(" · "), .text("I "), .percent("75", 75),
        ])
        #expect(MenuBarContent.pieces(.gauges, accounts: [], chosen: nil, threshold: 70) == nil)
    }
}
