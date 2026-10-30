import SwiftUI

/// One server in the popover gallery. Tapping it opens `MonitorDetailView`.
struct MonitorCardView: View {
    let name: String
    let result: CheckResult?
    let checking: Bool

    private var status: ServiceStatus { result?.status ?? .unknown }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: status.sfSymbol)
                    .foregroundStyle(status.color)
                    .font(.subheadline)
            }

            detail
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
        .overlay {
            if status.severity >= 2 {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(status.color.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(name)
    }

    @ViewBuilder
    private var detail: some View {
        if let result {
            let problems = result.problems
            if problems.isEmpty {
                Text(result.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(problems.prefix(ProviderCardView.maxImpacted), id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Image(systemName: item.status.sfSymbol)
                                .foregroundStyle(item.status.color)
                            Text("\(item.name): \(item.value)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if problems.count > ProviderCardView.maxImpacted {
                        Text("+\(problems.count - ProviderCardView.maxImpacted) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                Text(checking ? "Checking…" : "Not checked yet").foregroundStyle(.secondary).lineLimit(1)
                if checking { ProgressView().controlSize(.mini) }
            }
        }
    }
}

/// Every check of a server, worst first.
struct MonitorDetailView: View {
    let name: String
    let subtitle: String
    let result: CheckResult?
    let checking: Bool
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                let status = result?.status ?? .unknown
                Label(status.label, systemImage: status.sfSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)
            }

            if let result {
                VStack(spacing: 0) {
                    let items = result.problems + result.items.filter { $0.status.severity < 2 }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 6) {
                            Circle().fill(item.status.color).frame(width: 7, height: 7)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(item.value)
                                .fontWeight(item.status.severity >= 2 ? .semibold : .regular)
                                .foregroundStyle(item.status.severity >= 2 ? Color.primary : Color.secondary)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .padding(.vertical, 4)
                        if index < items.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            } else {
                Text("Not checked yet").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(action: recheck) {
                    HStack(spacing: 4) {
                        if checking { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                        Text("Check now")
                    }
                }
                .disabled(checking)
                if let checkedAt = result?.checkedAt {
                    Text("Checked \(checkedAt.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}
