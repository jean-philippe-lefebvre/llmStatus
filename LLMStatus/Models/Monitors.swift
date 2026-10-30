import Foundation

/// A server checked over SSH, set up in Settings > Servers.
/// Disk space, inodes, memory, load and failed systemd units are always checked;
/// services, containers and ports only when listed.
struct ServerMonitor: Codable, Hashable, Identifiable {
    var id = UUID()
    /// SSH alias from ~/.ssh/config, or user@host.
    var alias: String
    var name = ""
    var enabled = true
    /// systemd units that must be active, e.g. nginx, mysql.
    var services: [String] = []
    /// Docker containers that must be running.
    var containers: [String] = []
    /// TCP ports that must be listening on the server.
    var ports: [Int] = []
    /// Disk or inode use (percent) shown as degraded, then critical.
    var diskWarn = 80
    var diskCritical = 90

    var displayName: String { name.isEmpty ? alias : name }

    /// Names that can go into the remote script without quoting; anything else is dropped.
    static func isSafeName(_ name: String) -> Bool {
        !name.hasPrefix("-") && name.range(of: #"^[A-Za-z0-9@._:-]+$"#, options: .regularExpression) != nil
    }

    static func names(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
            .filter(isSafeName)
    }

    static func ports(from text: String) -> [Int] {
        text.split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Int($0) }
            .filter { (1...65535).contains($0) }
    }
}

/// One line of a check: "Disk /", "nginx", "Port 443"...
struct CheckItem: Hashable {
    var name: String
    var status: ServiceStatus
    var value: String
}

/// Last check of a server.
struct CheckResult: Equatable {
    var status: ServiceStatus
    /// Short line for the card when everything is fine, e.g. "Disk 45% · load 0.50".
    var summary: String
    var items: [CheckItem] = []
    var checkedAt = Date()

    /// Items not operational, worst first.
    var problems: [CheckItem] {
        items.filter { $0.status.severity >= 2 }.sorted { $0.status.severity > $1.status.severity }
    }

    /// Worst of the items; `fallback` when there are none.
    static func worst(_ items: [CheckItem], fallback: ServiceStatus = .operational) -> ServiceStatus {
        items.map(\.status).max { $0.severity < $1.severity } ?? fallback
    }
}
