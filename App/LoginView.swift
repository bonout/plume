import PlumeKit
import SwiftUI

/// Sign in with Login Flow v2 (in the browser), or with an app password
/// created by hand in the server's security settings.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var server = ""
    @State private var waiting: Task<Void, Never>?
    @State private var error: String?
    @State private var manual = false
    @State private var loginName = ""
    @State private var appPassword = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Plume").font(.largeTitle.bold())
                Text("A light client for your Nextcloud.").foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("Server address", text: $server, prompt: Text("cloud.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(signIn)

                if manual {
                    TextField("Login", text: $loginName)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("App password", text: $appPassword)
                        .onSubmit(signIn)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            if waiting != nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(manual ? "Checking…" : "Grant access in your browser, then come back here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Cancel") { cancel() }
                }
            } else {
                Button(action: signIn) {
                    Text(manual ? "Sign In" : "Sign In with Browser").frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(LoginFlow.normalizedServerURL(server) == nil)
                .keyboardShortcut(.defaultAction)

                Button(manual ? "Sign in with the browser instead" : "Use an app password instead") {
                    manual.toggle()
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        guard waiting == nil, let url = LoginFlow.normalizedServerURL(server) else { return }
        error = nil
        waiting = Task {
            do {
                let credentials: Credentials
                if manual {
                    credentials = try await LoginFlow.complete(server: url, loginName: loginName, appPassword: appPassword)
                } else {
                    let flow = try await LoginFlow.start(server: url)
                    openURL(flow.loginURL)
                    credentials = try await flow.credentials()
                }
                try model.signIn(credentials)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            waiting = nil
        }
    }

    private func cancel() {
        waiting?.cancel()
        waiting = nil
    }
}
