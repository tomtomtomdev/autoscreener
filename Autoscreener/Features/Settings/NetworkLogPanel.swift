import SwiftUI

struct NetworkLogPanel: View {
    let log: NetworkLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Network log").font(.headline)
                Spacer()
                Text("\(log.entries.count) entries").foregroundStyle(.secondary).font(.caption)
                Button("Clear") { log.clear() }
                    .controlSize(.small)
                    .disabled(log.entries.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if log.entries.isEmpty {
                        Text("No requests yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(log.entries) { entry in
                        NetworkLogRow(entry: entry)
                        Divider()
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }
}

struct NetworkLogRow: View {
    let entry: NetworkLog.Entry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                Text(entry.method).fontWeight(.semibold)
                statusBadge
                Text("\(entry.durationMS)ms").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))

            Text(entry.url)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)

            if let req = entry.requestBody {
                logBlock("→", req)
            }
            if let err = entry.error {
                logBlock("✗", err, color: .red)
            } else if let resp = entry.responseBody {
                logBlock("←", resp)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = entry.status {
            Text("\(status)")
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(badgeColor(status), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
        } else if entry.error != nil {
            Text("ERR")
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.red, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
        }
    }

    private func badgeColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .orange
        default: return .red
        }
    }

    @ViewBuilder
    private func logBlock(_ prefix: String, _ text: String, color: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(prefix).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(8)
                .textSelection(.enabled)
        }
    }
}
