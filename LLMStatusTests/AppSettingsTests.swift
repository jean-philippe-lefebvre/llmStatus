import Foundation
import Observation
import Testing
import os
@testable import LLMStatus

@Suite("Background and live settings", .serialized)
struct AppSettingsTests {
    @Test("Background resolves every choice with and without Reduce transparency")
    func backgroundResolution() {
        #expect(!AppBackground.system.isSolid(reduceTransparency: false))
        #expect(AppBackground.system.isSolid(reduceTransparency: true))
        #expect(!AppBackground.translucent.isSolid(reduceTransparency: false))
        #expect(!AppBackground.translucent.isSolid(reduceTransparency: true))
        #expect(AppBackground.solid.isSolid(reduceTransparency: false))
        #expect(AppBackground.solid.isSolid(reduceTransparency: true))
    }

    @Test("Runtime settings dispatch at launch and only when their saved value changes")
    func monitorSettingChanges() {
        let defaults = UserDefaults.standard
        let keys = ["refreshInterval", "notificationsEnabled", "menuBarProvider", "disabledProviders"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
        }
        defaults.set(60.0, forKey: "refreshInterval")
        defaults.set(true, forKey: "notificationsEnabled")
        defaults.set("all", forKey: "menuBarProvider")
        defaults.set("", forKey: "disabledProviders")

        let settings = AppSettings()
        var changes: [MonitorSettingChange] = []
        settings.onMonitorSettingChange = { changes.append($0) }
        settings.applyMonitorSettings()
        #expect(changes == [.disabledProviders([]), .notificationsEnabled(true),
                            .menuBarProvider("all"), .refreshInterval(60)])

        changes = []
        settings.refreshInterval = 120
        settings.notificationsEnabled = false
        settings.menuBarProvider = "openai"
        settings.toggleProvider("anthropic")
        #expect(changes == [.refreshInterval(120), .notificationsEnabled(false),
                            .menuBarProvider("openai"), .disabledProviders(["anthropic"])])

        changes = []
        settings.refreshInterval = 120
        settings.notificationsEnabled = false
        settings.menuBarProvider = "openai"
        settings.disabledProviderIDs = ["anthropic"]
        #expect(changes.isEmpty)

        settings.toggleProvider("anthropic")
        #expect(changes == [.disabledProviders([])])
    }

    @Test("Background defaults to macOS and changes invalidate an observed root")
    func backgroundObservation() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: AppBackground.key)
        defer { defaults.set(saved, forKey: AppBackground.key) }
        defaults.removeObject(forKey: AppBackground.key)
        let settings = AppSettings()
        settings.systemReducesTransparency = false
        #expect(settings.background == .system)
        #expect(!settings.usesSolidBackground)

        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = settings.usesSolidBackground
        } onChange: {
            changed.withLock { $0 = true }
        }
        settings.background = .solid
        #expect(changed.withLock { $0 })
        #expect(settings.usesSolidBackground)

        settings.background = .system
        changed.withLock { $0 = false }
        withObservationTracking {
            _ = settings.usesSolidBackground
        } onChange: {
            changed.withLock { $0 = true }
        }
        settings.systemReducesTransparency = true
        #expect(changed.withLock { $0 })
        #expect(settings.usesSolidBackground)

        settings.background = .translucent
        #expect(!settings.usesSolidBackground)
        settings.backgroundRaw = "unrecognized"
        #expect(settings.background == .system)
    }
}
