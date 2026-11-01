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
    @State private var showingHelp = false
    @State private var kind = Account.Kind.nextcloud

    private var serverURL: URL? {
        kind == .webdav ? LoginFlow.webDAVURL(server) : LoginFlow.normalizedServerURL(server)
    }

    private var usesPassword: Bool { manual || kind == .webdav }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image("Logo")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Text("Plume").font(.largeTitle.bold())
                Text("A light client for Nextcloud and WebDAV.").foregroundStyle(.secondary)
            }

            Picker("Server", selection: $kind) {
                Text("Nextcloud").tag(Account.Kind.nextcloud)
                Text("WebDAV").tag(Account.Kind.webdav)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .disabled(waiting != nil)

            Text(kind == .webdav ? "Enter the address of your WebDAV folder, your user name and your password."
                                 : "Enter the address of your Nextcloud server to sign in.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(spacing: 12) {
                TextField("Server address", text: $server,
                          prompt: Text(kind == .webdav ? "https://nas.example.com/webdav" : "cloud.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(signIn)

                if usesPassword {
                    TextField(kind == .webdav ? "User name" : "Login", text: $loginName)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField(kind == .webdav ? "Password" : "App password", text: $appPassword)
                        .onSubmit(signIn)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            if waiting != nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(usesPassword ? "Checking…" : "Grant access in your browser, then come back here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Cancel") { cancel() }
                }
            } else {
                Button(action: signIn) {
                    Text(usesPassword ? "Sign In" : "Sign In with Browser").frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(serverURL == nil)
                .keyboardShortcut(.defaultAction)

                if kind == .nextcloud {
                    Button(manual ? "Sign in with the browser instead" : "Use an app password instead") {
                        manual.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button("What is Nextcloud?", systemImage: "questionmark.circle") { showingHelp = true }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if server.isEmpty { server = DebugLaunch.serverField ?? model.lastServer } }
        .sheet(isPresented: $showingHelp) {
            NavigationStack {
                NextcloudHelp()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingHelp = false } }
                    }
            }
            #if os(macOS)
            .frame(width: 440, height: 420)
            #endif
        }
    }

    private func signIn() {
        guard waiting == nil, let url = serverURL else { return }
        error = nil
        waiting = Task {
            do {
                let credentials: Credentials
                if kind == .webdav {
                    credentials = try await LoginFlow.signInWebDAV(server: url, user: loginName, password: appPassword)
                } else if manual {
                    credentials = try await LoginFlow.complete(server: url, loginName: loginName, appPassword: appPassword)
                } else {
                    let flow = try await LoginFlow.start(server: url)
                    openURL(flow.loginURL)
                    credentials = try await flow.credentials()
                }
                try model.signIn(credentials)
            } catch is CancellationError {
            } catch PlumeError.unauthorized where kind == .webdav {
                self.error = String(localized: "Wrong user name or password.")
            } catch PlumeError.unauthorized where manual {
                self.error = String(localized: "Wrong login or app password. With two-factor authentication, your account password won't work here: create an app password in Nextcloud under Settings → Security, or sign in with the browser.")
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

struct NextcloudHelp: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nextcloud is free, open-source software for keeping your files on a server you choose: one you run at home, or one from a hosting provider. Your files stay on that server, not with a big tech company.")
                Text("Plume is an app for your Nextcloud: it shows the files of your account, finds them as you type, keeps the ones you choose on this device, and puts them in Files and Finder.")
                Text("To use Plume you need a Nextcloud account. Enter the address you use to open Nextcloud in a browser, then sign in there: Plume receives its own app password, which you can revoke at any time.")
                Link("Learn more about Nextcloud", destination: URL(string: "https://nextcloud.com/files/")!)
                Link("Find a Nextcloud provider", destination: URL(string: "https://nextcloud.com/providers/")!)
                Text("Plume is an independent app, not affiliated with Nextcloud GmbH.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("What is Nextcloud?")
    }
}
