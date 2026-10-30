import Foundation
import UserNotifications

@Observable
class NotificationManager {
    private struct NotifiedEntry {
        let status: IncidentStatus
        let date: Date
    }

    /// Tracks "providerID-incidentID" → last notified status + timestamp
    private var notifiedIncidents: [String: NotifiedEntry] = [:]
    /// Tracks providerIDs that already received a recovery notification
    private var notifiedRecoveries: Set<String> = []

    /// Request notification permission from macOS.
    func requestPermission() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Check if we should notify for this incident (new or status changed).
    func shouldNotify(providerID: String, incident: Incident) -> Bool {
        let key = Self.notificationIdentifier(providerID: providerID, incidentID: incident.id)
        guard let entry = notifiedIncidents[key] else {
            return true // never notified
        }
        return entry.status != incident.status // status changed
    }

    /// Mark an incident as notified with its current status.
    func markNotified(providerID: String, incident: Incident) {
        let key = Self.notificationIdentifier(providerID: providerID, incidentID: incident.id)
        notifiedIncidents[key] = NotifiedEntry(status: incident.status, date: Date())
    }

    /// Remove entries older than 24h to prevent unbounded growth.
    func purgeStaleEntries() {
        let cutoff = Date().addingTimeInterval(-86400)
        notifiedIncidents = notifiedIncidents.filter { $0.value.date > cutoff }
    }

    /// Send a macOS notification for an incident.
    func sendIncidentNotification(providerName: String, providerID: String, incident: Incident) async {
        guard shouldNotify(providerID: providerID, incident: incident) else { return }

        let identifier = Self.notificationIdentifier(providerID: providerID, incidentID: incident.id)
        await deliver(
            title: "\(providerName) — \(incident.impact.rawValue.capitalized)",
            body: incident.name,
            identifier: identifier
        )
        markNotified(providerID: providerID, incident: incident)
    }

    /// Send a recovery notification when a provider returns to operational.
    func sendRecoveryNotification(providerName: String, providerID: String) async {
        guard !notifiedRecoveries.contains(providerID) else { return }
        notifiedRecoveries.insert(providerID)
        await deliver(
            title: "\(providerName) — Recovered",
            body: "All systems operational",
            identifier: "recovery-\(providerID)"
        )
    }

    /// Clear recovery tracking when a provider goes down (so next recovery triggers again).
    func clearRecovery(providerID: String) {
        notifiedRecoveries.remove(providerID)
    }

    /// Alert for a server whose status changed (see `InfraMonitor.alert`).
    func sendMonitorNotification(title: String, body: String, identifier: String) async {
        await deliver(title: title, body: body, identifier: identifier)
    }

    private func deliver(title: String, body: String, identifier: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Deterministic identifier for deduplication.
    static func notificationIdentifier(providerID: String, incidentID: String) -> String {
        "\(providerID)-\(incidentID)"
    }
}
