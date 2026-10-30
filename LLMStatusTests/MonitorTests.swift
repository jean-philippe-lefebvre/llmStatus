import Testing
import Foundation
@testable import LLMStatus

@Suite("Server checks")
struct ServerCheckerTests {
    var server: ServerMonitor {
        var server = ServerMonitor(alias: "vps")
        server.services = ["nginx", "mysql"]
        server.containers = ["app"]
        server.ports = [443]
        return server
    }

    let healthy = """
    disk|/|45|20000000
    inode|/|10
    mem|60
    load|0.50|4
    uptime|90000
    unit|nginx|active
    unit|mysql|active
    container|app|running/healthy
    port|443|open
    ok|end
    """

    @Test("Healthy output is operational with a disk summary")
    func healthyServer() {
        let result = ServerChecker.evaluate(healthy, elapsed: 0.8, server: server)
        #expect(result.status == .operational)
        #expect(result.summary == "Disk 45% · load 0.50")
        #expect(!result.items.contains { $0.name.hasPrefix("Inodes") })
    }

    @Test("Disk thresholds")
    func disk() {
        #expect(ServerChecker.evaluate("disk|/|85|100\nok|end", elapsed: 1, server: server).status == .degraded)
        #expect(ServerChecker.evaluate("disk|/|95|100\nok|end", elapsed: 1, server: server).status == .critical)
        #expect(ServerChecker.evaluate("inode|/|92\nok|end", elapsed: 1, server: server).status == .critical)
    }

    @Test("Stopped service, unhealthy container and closed port are reported")
    func services() {
        let output = healthy
            .replacingOccurrences(of: "unit|mysql|active", with: "unit|mysql|inactive")
            .replacingOccurrences(of: "running/healthy", with: "running/unhealthy")
            .replacingOccurrences(of: "port|443|open", with: "port|443|closed")
        let result = ServerChecker.evaluate(output, elapsed: 1, server: server)
        #expect(result.status == .critical)
        let names = Set(result.problems.map(\.name))
        #expect(names == ["mysql", "🐳 app", "Port 443"])
    }

    @Test("Failed units not listed are a major outage; listed ones are not duplicated")
    func failedUnits() {
        let output = healthy + "\nfailed|backup.service\nfailed|nginx.service\nfailed|run-u35012.service"
        let result = ServerChecker.evaluate(output, elapsed: 1, server: server)
        #expect(result.status == .majorOutage)
        #expect(result.problems.map(\.name) == ["backup"])
    }

    @Test("High load and low memory")
    func pressure() {
        #expect(ServerChecker.evaluate("load|10|4\nok|end", elapsed: 1, server: server).status == .degraded)
        #expect(ServerChecker.evaluate("mem|3\nok|end", elapsed: 1, server: server).status == .majorOutage)
        #expect(ServerChecker.evaluate("ok|end", elapsed: 9, server: server).status == .degraded)
    }

    @Test("Unsafe names never reach the script")
    func scriptSafety() {
        var server = server
        server.services = ["nginx", "x'; rm -rf /", "-evil"]
        server.ports = [80, 70000]
        let script = ServerChecker.script(for: server)
        #expect(script.hasPrefix("SERVICES='nginx'\nCONTAINERS='app'\nPORTS='80'\n"))
        #expect(ServerMonitor.names(from: "nginx, php8.2-fpm  docker@app") == ["nginx", "php8.2-fpm", "docker@app"])
    }

    @Test("ssh errors become short reasons")
    func sshReasons() {
        #expect(ServerChecker.sshReason("user@host: Permission denied (publickey).", status: 255) == "SSH login refused (key?)")
        #expect(ServerChecker.sshReason("ssh: connect to host x port 22: Connection timed out", status: 255) == "SSH timed out")
    }
}

@Suite("Monitor alerts")
struct MonitorAlertTests {
    @Test("Alerts on going down, getting worse and recovering; never on unknown")
    func alerts() {
        let down = CheckResult(status: .critical, summary: "Timed out", items: [CheckItem(name: "Connection", status: .critical, value: "Timed out")])
        let ok = CheckResult(status: .operational, summary: "Disk 45% · load 0.50")
        let unknown = CheckResult(status: .unknown, summary: "No connection")
        #expect(InfraMonitor.alert(name: "Server", previous: .operational, result: down)?.title == "Server: Critical")
        #expect(InfraMonitor.alert(name: "Server", previous: nil, result: down) != nil)
        #expect(InfraMonitor.alert(name: "Server", previous: .degraded, result: down) != nil)
        #expect(InfraMonitor.alert(name: "Server", previous: .critical, result: down) == nil)
        #expect(InfraMonitor.alert(name: "Server", previous: .critical, result: ok)?.title == "Server: Recovered")
        #expect(InfraMonitor.alert(name: "Server", previous: .operational, result: ok) == nil)
        #expect(InfraMonitor.alert(name: "Server", previous: .operational, result: unknown) == nil)
    }
}
