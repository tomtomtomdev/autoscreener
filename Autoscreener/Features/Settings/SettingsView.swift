import SwiftUI

struct SettingsView: View {
    @State private var vm: SettingsViewModel
    @State private var log = NetworkLog.shared

    init() {
        let deps = AppDependencies.shared
        _vm = State(initialValue: SettingsViewModel(
            loginService: deps.loginService,
            verificationService: deps.deviceVerificationService,
            tokens: deps.tokens
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Stockbit Account") {
                    switch vm.phase {
                    case .signIn, .signedIn:
                        signInRows
                    case .verifying(let state):
                        verificationRows(state)
                    }
                }
            }
            .formStyle(.grouped)

            NetworkLogPanel(log: log)
                .padding(.horizontal)
                .padding(.bottom)
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    // MARK: - Sign in rows

    @ViewBuilder
    private var signInRows: some View {
        TextField("Username or email", text: $vm.username)
            .textContentType(.username)
            .autocorrectionDisabled()
            .disabled(vm.isSignedIn || vm.isSubmitting)

        SecureField("Password", text: $vm.password)
            .textContentType(.password)
            .disabled(vm.isSignedIn || vm.isSubmitting)

        HStack {
            Button(vm.isSignedIn ? "Sign out" : "Sign in") {
                Task { await vm.submit() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(vm.isSubmitting || (!vm.isSignedIn && (vm.username.isEmpty || vm.password.isEmpty)))

            if vm.isSubmitting {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }

        if let error = vm.error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
        if vm.isSignedIn {
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        }
    }

    // MARK: - Verification rows

    @ViewBuilder
    private func verificationRows(_ state: SettingsViewModel.VerificationState) -> some View {
        Text("New device detected. Choose where Stockbit should send your one-time code.")
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            ForEach(state.availableChannels) { channel in
                Button(action: { Task { await vm.requestOTP(via: channel) } }) {
                    Label(buttonLabel(for: channel, state: state),
                          systemImage: icon(for: channel))
                }
                .disabled(state.isSubmitting)
            }
            if state.isSubmitting {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }

        if let sent = state.sentChannel {
            Label("Code sent via \(sent.displayName). Check your inbox / chats.",
                  systemImage: "envelope.badge")
                .font(.callout)
                .foregroundStyle(.green)

            TextField("6-digit code", text: Binding(
                get: { state.otp },
                set: { vm.updateOTP($0) }
            ))
            .textContentType(.oneTimeCode)
            .font(.system(.title3, design: .monospaced))
            .disabled(state.isSubmitting)

            HStack {
                Button("Verify") { Task { await vm.verifyOTP() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isSubmitting || state.otp.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {
                    Task { await vm.cancelVerification() }
                }
            }
        }

        if let error = state.error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
    }

    private func buttonLabel(for channel: OTPChannel, state: SettingsViewModel.VerificationState) -> String {
        if state.sentChannel == channel { return "Resend \(channel.displayName)" }
        if state.sentChannel != nil { return "Switch to \(channel.displayName)" }
        return "Send via \(channel.displayName)"
    }

    private func icon(for channel: OTPChannel) -> String {
        switch channel {
        case .email: return "envelope"
        case .whatsapp: return "message"
        }
    }
}

private struct NetworkLogPanel: View {
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
            .frame(height: 220)
        }
    }
}

private struct NetworkLogRow: View {
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
                .lineLimit(6)
                .textSelection(.enabled)
        }
    }
}

#Preview { SettingsView() }
