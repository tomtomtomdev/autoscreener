import SwiftUI

struct SettingsView: View {
    @State private var vm: SettingsViewModel

    init() {
        let deps = AppDependencies.shared
        _vm = State(initialValue: SettingsViewModel(loginService: deps.loginService, tokens: deps.tokens))
    }

    var body: some View {
        Form {
            Section("Stockbit Account") {
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}

#Preview {
    SettingsView()
}
