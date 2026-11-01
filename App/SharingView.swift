import PlumeKit
import SwiftUI

/// Who can open an item: its public links (password, expiry, editing) and
/// the users or groups of the server it is shared with.
struct SharingView: View {
    let item: RemoteItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shares: [Share]?
    @State private var editing: LinkDraft?
    @State private var search = ""
    @State private var sharees: [Sharee] = []
    @State private var failure: String?
    @State private var copied: Share.ID?

    var body: some View {
        Form {
            Section {
                ForEach(links) { link in
                    linkRow(link)
                }
                if model.capabilities.linksEnabled {
                    Button("New Link", systemImage: "link.badge.plus") {
                        editing = LinkDraft(share: nil, capabilities: model.capabilities)
                    }
                }
            } header: {
                Text("Public Links")
            } footer: {
                Text("Anyone with a link can open \(item.isDirectory ? "this folder" : "this file"), without an account.")
            }

            Section("People") {
                ForEach(people) { share in
                    personRow(share)
                }
                TextField("Add a user or group", text: $search)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                ForEach(sharees.filter { sharee in !people.contains { $0.shareWith == sharee.shareWith } }) { sharee in
                    Button {
                        Task { await add(sharee) }
                    } label: {
                        Label(sharee.label, systemImage: sharee.isGroup ? "person.3" : "person.crop.circle.badge.plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay { if shares == nil && failure == nil { ProgressView() } }
        .navigationTitle("Share “\(item.name)”")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
        .task(id: search) {
            let term = search.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2, let client = model.repository?.client else {
                sharees = []
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            sharees = (try? await client.sharees(matching: term, isDirectory: item.isDirectory)) ?? []
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                LinkEditor(draft: draft, isDirectory: item.isDirectory) { result in
                    Task { await save(result) }
                }
            }
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 320)
            #endif
        }
        .alert("Sharing", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private var links: [Share] { (shares ?? []).filter { $0.kind == .link } }
    private var people: [Share] { (shares ?? []).filter { $0.kind == .user || $0.kind == .group } }

    private func linkRow(_ link: Share) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.label ?? link.url?.absoluteString ?? "Link").lineLimit(1).truncationMode(.middle)
                Text(summary(link)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = link.url {
                Button(copied == link.id ? "Copied" : "Copy", systemImage: copied == link.id ? "checkmark" : "doc.on.doc") {
                    Platform.copyToPasteboard(url.absoluteString)
                    copied = link.id
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
            }
            Menu {
                Button("Edit…", systemImage: "slider.horizontal.3") {
                    editing = LinkDraft(share: link, capabilities: model.capabilities)
                }
                Button("Delete Link", systemImage: "trash", role: .destructive) {
                    Task { await run { try await $0.delete(link) } }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func personRow(_ share: Share) -> some View {
        HStack {
            Label(share.displayName ?? share.shareWith ?? "", systemImage: share.kind == .group ? "person.3" : "person")
            Spacer()
            Toggle("Can edit", isOn: Binding(get: { share.canEdit }, set: { edit in
                Task {
                    let permissions = edit ? Permission.edit(isDirectory: item.isDirectory) | Permission.share
                                           : Permission.read | Permission.share
                    await run { _ = try await $0.update(share, permissions: permissions) }
                }
            }))
            .fixedSize()
            Button("Remove", systemImage: "xmark.circle.fill", role: .destructive) {
                Task { await run { try await $0.delete(share) } }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    private func summary(_ link: Share) -> String {
        var parts = [link.canEdit ? (item.isDirectory ? String(localized: "Can upload and edit") : String(localized: "Can edit")) : String(localized: "View only")]
        if link.hasPassword { parts.append("Password") }
        if let expiration = link.expiration {
            parts.append("Expires " + expiration.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = model.repository?.client else { return }
        do {
            shares = try await client.shares(of: item.path)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func add(_ sharee: Sharee) async {
        search = ""
        await run { _ = try await $0.share(item.path, with: sharee, permissions: Permission.read | Permission.share) }
    }

    private func save(_ draft: LinkDraft) async {
        let permissions = draft.canEdit ? Permission.edit(isDirectory: item.isDirectory) : Permission.read
        let expiration = draft.expires ? draft.expiration : nil
        await run { client in
            if let share = draft.share {
                _ = try await client.update(
                    share,
                    permissions: permissions == share.permissions ? nil : permissions,
                    // Unchanged password field: keep it; emptied: remove it.
                    password: draft.passwordChanged ? (draft.usesPassword ? draft.password : "") : nil,
                    expiration: expiration == share.expiration ? nil : .some(expiration))
            } else {
                _ = try await client.createLink(for: item.path, permissions: permissions,
                                                password: draft.usesPassword ? draft.password : nil,
                                                expiration: expiration)
            }
        }
    }

    private func run(_ action: (NextcloudClient) async throws -> Void) async {
        guard let client = model.repository?.client else { return }
        do {
            try await action(client)
        } catch {
            failure = error.localizedDescription
        }
        await load()
        model.changed()
    }
}

/// A link being created or edited.
struct LinkDraft: Identifiable {
    let id = UUID()
    let share: Share?
    var canEdit: Bool
    var usesPassword: Bool
    var password = ""
    var passwordChanged = false
    var expires: Bool
    var expiration: Date
    let passwordRequired: Bool
    let maxDays: Int?

    init(share: Share?, capabilities: ServerCapabilities) {
        self.share = share
        canEdit = share?.canEdit ?? false
        passwordRequired = capabilities.linkPasswordRequired
        usesPassword = share?.hasPassword ?? capabilities.linkPasswordRequired
        maxDays = capabilities.linkMaxDays
        expires = share?.expiration != nil || capabilities.linkMaxDays != nil
        expiration = share?.expiration
            ?? Calendar.current.date(byAdding: .day, value: min(capabilities.linkMaxDays ?? 30, 30), to: .now)!
    }

    var latestExpiration: Date? {
        maxDays.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: .now) }
    }

    var isValid: Bool {
        !(usesPassword && (share?.hasPassword != true || passwordChanged) && password.isEmpty)
    }
}

struct LinkEditor: View {
    @State var draft: LinkDraft
    let isDirectory: Bool
    let onSave: (LinkDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Toggle(isDirectory ? "Allow upload and editing" : "Allow editing", isOn: $draft.canEdit)
            Section {
                Toggle("Password", isOn: $draft.usesPassword)
                    .disabled(draft.passwordRequired)
                    .onChange(of: draft.usesPassword) { draft.passwordChanged = true }
                if draft.usesPassword {
                    SecureField(draft.share?.hasPassword == true ? "Unchanged" : "Password", text: $draft.password)
                        .onChange(of: draft.password) { draft.passwordChanged = true }
                }
            } footer: {
                if draft.passwordRequired { Text("The server requires a password on links.") }
            }
            Section {
                Toggle("Expires", isOn: $draft.expires)
                    .disabled(draft.maxDays != nil)
                if draft.expires {
                    DatePicker("On", selection: $draft.expiration,
                               in: Date.now.addingTimeInterval(86_400)...(draft.latestExpiration ?? .distantFuture),
                               displayedComponents: .date)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.share == nil ? "New Link" : "Edit Link")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.share == nil ? "Create" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(!draft.isValid)
            }
        }
    }
}
