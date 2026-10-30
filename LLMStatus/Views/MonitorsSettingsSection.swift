import SwiftUI

/// Settings > Servers: servers checked over SSH.
/// Adding, editing or switching one saves right away and checks it.
struct MonitorsSettingsSection: View {
    @Bindable var settings: AppSettings
    var infra: InfraMonitor
    @State private var servers: [ServerMonitor] = []
    @State private var newAlias = ""

    private var trimmedAlias: String { newAlias.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            Section("Servers") {
                ForEach($servers) { $server in
                    ServerRow(server: $server, result: infra.results[server.id], checking: infra.checking.contains(server.id),
                              isAvailable: { alias in RemoteUsage.isValidHost(alias) && !servers.contains { $0.alias == alias && $0.id != server.id } },
                              onRemove: { servers.removeAll { $0.id == server.id } },
                              onCommit: { check(server.id) })
                }
                HStack {
                    TextField("Add server", text: $newAlias, prompt: Text("SSH alias, e.g. my-vps"))
                        .labelsHidden()
                        .onSubmit(addServer)
                    Button("Add", action: addServer)
                        .disabled(!canAddServer)
                }
                if !trimmedAlias.isEmpty, !RemoteUsage.isValidHost(trimmedAlias) {
                    Hint(text: "Use an alias from ~/.ssh/config or user@host.", status: .degraded)
                        .font(.caption)
                }
                Picker("Check every", selection: $settings.serverCheckInterval) {
                    ForEach(AppSettings.serverIntervalOptions, id: \.value) { Text($0.label).tag($0.value) }
                }
                Text("Over SSH with your key (no password prompt): SSH answer time, disk space and inodes, memory, load and failed systemd units, plus the services, Docker containers and ports you list. Click a server to list them and set disk thresholds. Read-only; uses sudo -n when allowed (needed for Docker unless your user is in the docker group).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            servers = settings.servers
        }
        .onChange(of: servers) { _, servers in
            settings.servers = servers
            infra.servers = servers
            infra.prune()
        }
        .onChange(of: settings.serverCheckInterval) { _, interval in infra.serverInterval = interval }
    }

    private var canAddServer: Bool {
        RemoteUsage.isValidHost(trimmedAlias) && !servers.contains { $0.alias == trimmedAlias }
    }

    private func addServer() {
        guard canAddServer else { return }
        let server = ServerMonitor(alias: trimmedAlias)
        servers.append(server)
        newAlias = ""
        check(server.id)
    }

    /// The list reaches the monitor through onChange first: check on the next turn.
    private func check(_ id: UUID) {
        Task { @MainActor in
            await Task.yield()
            await infra.check(id: id)
        }
    }
}

private struct StatusDot: View {
    let result: CheckResult?
    let enabled: Bool

    var body: some View {
        Circle()
            .fill(enabled ? (result?.status ?? .unknown).color : .gray)
            .frame(width: 7, height: 7)
    }
}

private struct RowControls: View {
    let checking: Bool
    @Binding var enabled: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        if checking {
            ProgressView().controlSize(.mini)
        }
        Toggle("Enabled", isOn: Binding(get: { enabled }, set: { enabled = $0; onToggle() }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        Button(action: onRemove) { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
    }
}

/// The status of a monitor with a problem; nil when fine, off or not checked.
private func problem(_ result: CheckResult?, _ enabled: Bool) -> ServiceStatus? {
    guard enabled, let status = result?.status, status.severity >= 2 else { return nil }
    return status
}

/// Secondary text, or primary text after a colored symbol when `status` is set:
/// orange or yellow text is hard to read on the popover's light material.
private struct Hint: View {
    let text: String
    let status: ServiceStatus?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let status {
                Image(systemName: status.sfSymbol)
                    .foregroundStyle(status.color)
            }
            Text(text)
                .foregroundStyle(status == nil ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func statusLine(_ result: CheckResult?, enabled: Bool, checking: Bool) -> String {
    guard enabled else { return "Off" }
    if checking { return "Checking…" }
    guard let result else { return "Not checked yet" }
    let time = result.checkedAt.formatted(date: .omitted, time: .shortened)
    let problems = result.problems.prefix(2).map { "\($0.name): \($0.value)" }
    return (problems.isEmpty ? result.summary : problems.joined(separator: " · ")) + " · \(time)"
}

private struct ServerRow: View {
    @Binding var server: ServerMonitor
    let result: CheckResult?
    let checking: Bool
    let isAvailable: (String) -> Bool
    let onRemove: () -> Void
    let onCommit: () -> Void
    @State private var editing = false
    @State private var alias = ""
    @State private var name = ""
    @State private var services = ""
    @State private var containers = ""
    @State private var ports = ""
    @State private var warn = 80
    @State private var critical = 90

    private var trimmedAlias: String { alias.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(result: result, enabled: server.enabled)
                VStack(alignment: .leading, spacing: 0) {
                    Text(server.displayName).lineLimit(1).truncationMode(.middle)
                    if !server.name.isEmpty {
                        Text(server.alias).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: startEditing)
                .help("Click to edit")
                Spacer()
                RowControls(checking: checking, enabled: $server.enabled, onToggle: onCommit, onRemove: onRemove)
            }

            if editing {
                TextField("SSH alias", text: $alias, prompt: Text("SSH alias or user@host"))
                TextField("Name", text: $name, prompt: Text("Display name (optional)"))
                TextField("Services", text: $services, prompt: Text("systemd services: nginx, mysql"))
                TextField("Containers", text: $containers, prompt: Text("Docker containers (optional)"))
                TextField("Ports", text: $ports, prompt: Text("Ports that must listen: 80, 443"))
                Stepper("Disk warning at \(warn)%", value: $warn, in: 50...99)
                Stepper("Disk critical at \(critical)%", value: $critical, in: (warn + 1)...100)
                HStack {
                    Hint(text: isAvailable(trimmedAlias) ? "Return to save, Esc to cancel." : "Use a unique alias from ~/.ssh/config or user@host.",
                         status: isAvailable(trimmedAlias) ? nil : .degraded)
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: commit)
                        .disabled(!isAvailable(trimmedAlias))
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            } else {
                Hint(text: statusLine(result, enabled: server.enabled, checking: checking), status: problem(result, server.enabled))
                    .font(.caption2)
                let watched = server.services + server.containers.map { "🐳 " + $0 } + server.ports.map { ":\($0)" }
                if !watched.isEmpty {
                    Text(watched.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit(commit)
        .onExitCommand { editing = false }
    }

    private func startEditing() {
        alias = server.alias
        name = server.name
        services = server.services.joined(separator: ", ")
        containers = server.containers.joined(separator: ", ")
        ports = server.ports.map(String.init).joined(separator: ", ")
        warn = server.diskWarn
        critical = max(server.diskCritical, server.diskWarn + 1)
        editing = true
    }

    private func commit() {
        guard editing, isAvailable(trimmedAlias) else { return }
        server.alias = trimmedAlias
        server.name = name.trimmingCharacters(in: .whitespaces)
        server.services = ServerMonitor.names(from: services)
        server.containers = ServerMonitor.names(from: containers)
        server.ports = ServerMonitor.ports(from: ports)
        server.diskWarn = warn
        server.diskCritical = max(critical, warn + 1)
        editing = false
        onCommit()
    }
}
