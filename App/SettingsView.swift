import PlumeKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var info: NextcloudClient.UserInfo?
    @State private var offlineSize: Int64 = 0
    @State private var cacheSize: Int64 = 0
    @State private var indexed = 0
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            if let account = model.credentials?.account {
                Section("Account") {
                    LabeledContent("Name", value: account.displayName ?? account.loginName)
                    LabeledContent("Server", value: account.host)
                    if let info, let used = info.quotaUsed {
                        if let total = info.quotaTotal {
                            LabeledContent("Storage") {
                                VStack(alignment: .trailing) {
                                    Text("\(bytes(used)) of \(bytes(total))")
                                    ProgressView(value: Double(used), total: Double(total)).frame(width: 140)
                                }
                            }
                        } else {
                            LabeledContent("Storage used", value: bytes(used))
                        }
                    }
                }
            }
            Section {
                LabeledContent("Available offline", value: bytes(offlineSize))
                LabeledContent("Recently opened", value: bytes(cacheSize))
                LabeledContent("Indexed for search", value: model.indexComplete
                               ? "\(indexed.formatted()) items" : "In progress…")
                Button("Clear Recently Opened Files") {
                    model.repository?.files.clearCache()
                    measure()
                }
            } header: {
                Text("On This Device")
            } footer: {
                Text("Recently opened files are kept to reopen them instantly, up to 2 GB.")
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            measure()
            info = try? await model.repository?.client.userInfo()
        }
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Files kept on this device are removed. Nothing is deleted from the server.")
        }
    }

    private func measure() {
        guard let files = model.repository?.files else { return }
        offlineSize = files.size(of: files.offlineRoot)
        indexed = max(0, (model.repository?.store.count ?? 1) - 1)
        cacheSize = files.size(of: files.cacheRoot)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
