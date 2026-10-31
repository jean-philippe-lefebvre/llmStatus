import SwiftUI

/// Settings section listing the SSH hosts whose Codex usage joins the breakdown.
/// Adding, renaming, removing or switching a host syncs right away.
struct RemoteHostsSection: View {
    @Bindable var settings: AppSettings
    var usage: UsageMonitor
    @State private var hosts: [RemoteUsage.Host] = []
    @State private var hostsAtAppear: [RemoteUsage.Host] = []
    @State private var newAlias = ""

    private var trimmedAlias: String { newAlias.trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool { isAvailable(trimmedAlias, for: nil) }

    var body: some View {
        Section("Codex breakdown from SSH hosts") {
            ForEach($hosts) { $host in
                RemoteHostRow(
                    host: $host,
                    status: usage.hostStatus[host.alias],
                    checking: usage.checkingHosts.contains(host.alias),
                    isAvailable: { isAvailable($0, for: host.id) },
                    onRemove: { remove(host) },
                    onCommit: sync
                )
            }

            HStack {
                TextField("Add host", text: $newAlias, prompt: Text("SSH alias, e.g. my-vps"))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!canAdd)
            }
            if !trimmedAlias.isEmpty, !RemoteUsage.isValidHost(trimmedAlias) {
                Text("Use an alias from ~/.ssh/config or user@host.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Adds this Mac's Codex usage on these hosts to its breakdown (Codex, Hermes and codex-usage.jsonl, found by content). Read-only: only token totals and names leave the host. Click a host to edit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            hosts = settings.remoteHosts
            hostsAtAppear = hosts
        }
        .onChange(of: hosts) { _, hosts in
            settings.remoteHosts = hosts
            usage.remoteHosts = hosts
            // Statuses of renamed or removed hosts go away with them.
            let aliases = Set(hosts.map(\.alias))
            for alias in usage.hostStatus.keys where !aliases.contains(alias) {
                usage.hostStatus[alias] = nil
            }
        }
        .onDisappear {
            if hosts != hostsAtAppear { sync() }
        }
    }

    /// A valid alias no other host uses.
    private func isAvailable(_ alias: String, for id: UUID?) -> Bool {
        RemoteUsage.isValidHost(alias) && !hosts.contains { $0.alias == alias && $0.id != id }
    }

    private func add() {
        guard canAdd else { return }
        hosts.append(RemoteUsage.Host(alias: trimmedAlias))
        newAlias = ""
        sync()
    }

    private func remove(_ host: RemoteUsage.Host) {
        hosts.removeAll { $0.id == host.id }
        sync()
    }

    private func sync() {
        hostsAtAppear = hosts
        usage.remoteHosts = hosts
        Task {
            // The breakdown refresh reads the hosts only while the Codex row is shown.
            if usage.localKinds.contains(.codex) {
                await usage.refresh()
            } else {
                for host in hosts where host.enabled { await usage.check(host) }
            }
        }
    }
}

private struct RemoteHostRow: View {
    @Binding var host: RemoteUsage.Host
    let status: RemoteUsage.Status?
    let checking: Bool
    let isAvailable: (String) -> Bool
    let onRemove: () -> Void
    let onCommit: () -> Void
    @State private var editing = false
    @State private var alias = ""
    @State private var folders = ""
    @FocusState private var aliasFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                if editing {
                    TextField("Alias", text: $alias)
                        .labelsHidden()
                        .focused($aliasFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                } else {
                    Text(host.alias)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: startEditing)
                        .help("Click to edit")
                }
                Spacer()
                if checking {
                    ProgressView().controlSize(.mini)
                }
                Toggle("Enabled", isOn: Binding(
                    get: { host.enabled },
                    set: { host.enabled = $0; onCommit() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                Button(action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove host")
            }

            if editing {
                TextField("Extra folders", text: $folders, prompt: Text("Extra folders: /srv/apps, /data"))
                    .font(.caption)
                    .onSubmit(commit)
                HStack {
                    Text(isAvailable(trimmed) ? "Return to save, Esc to cancel." : "Use a unique alias from ~/.ssh/config or user@host.")
                        .foregroundStyle(isAvailable(trimmed) ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: commit)
                        .disabled(!isAvailable(trimmed))
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            } else {
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if host.enabled, let error = status?.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var trimmed: String { alias.trimmingCharacters(in: .whitespaces) }

    private func startEditing() {
        alias = host.alias
        folders = host.extraPaths.joined(separator: ", ")
        editing = true
        aliasFocused = true
    }

    private func commit() {
        guard isAvailable(trimmed) else { return }
        host.alias = trimmed
        host.extraPaths = folders.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        editing = false
        onCommit()
    }

    private var statusLine: String {
        guard host.enabled else { return "Off" }
        if checking { return "Checking…" }
        guard let status else { return "Not checked yet" }
        let time = status.checkedAt.formatted(date: .omitted, time: .shortened)
        guard let found = status.found else { return "Checked \(time)" }
        return "\(found.summary) · \(time)"
    }

    private var dotColor: Color {
        guard host.enabled, let status else { return .gray }
        if status.found == nil { return .red }
        return status.error == nil ? .green : .orange
    }
}
