import SwiftUI

struct SettingsView: View {
    @State private var vm: SettingsViewModel
    @State private var log = NetworkLog.shared

    init() {
        let deps = AppDependencies.shared
        _vm = State(initialValue: SettingsViewModel(
            loginService: deps.loginService,
            verificationService: deps.deviceVerificationService,
            tokens: deps.tokens,
            authState: deps.authState,
            autoRehydrate: !ProcessInfo.processInfo.isRunningUnitTests
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
                .frame(height: 220)
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
        Text(prompt(for: state))
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            ForEach(state.availableChannels, id: \.channel) { item in
                Button(action: { Task { await vm.requestOTP(via: item.channel) } }) {
                    Label(buttonLabel(for: item.channel, state: state),
                          systemImage: item.channel.iconName)
                }
                .disabled(state.isSubmitting)
            }
            if state.isSubmitting {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }

        if let sent = state.sentChannel {
            Label(sentCopy(channel: sent, target: state.sentTarget),
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

    private func prompt(for state: SettingsViewModel.VerificationState) -> String {
        switch state.step {
        case 1:
            return "New device detected. Choose where Stockbit should send your one-time code."
        default:
            return "One more step. Stockbit needs to verify your phone number too — pick a channel for the next code."
        }
    }

    private func sentCopy(channel: OTPChannel, target: String?) -> String {
        if let target {
            return "Code sent via \(channel.displayName) to \(target)."
        } else {
            return "Code sent via \(channel.displayName). Check your inbox / chats."
        }
    }

    private func buttonLabel(for channel: OTPChannel, state: SettingsViewModel.VerificationState) -> String {
        if state.sentChannel == channel { return "Resend \(channel.displayName)" }
        if state.sentChannel != nil { return "Switch to \(channel.displayName)" }
        return "Send via \(channel.displayName)"
    }
}

#Preview { SettingsView() }
