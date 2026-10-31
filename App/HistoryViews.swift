import PlumeKit
import PlumeUI
import QuickLook
import SwiftUI

/// The earlier versions of a file: look at one, or make it current again.
struct VersionsView: View {
    let item: RemoteItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [FileVersion]?
    @State private var restoring: FileVersion?
    @State private var preview: URL?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Current version", value: item.summary)
            }
            Section("Earlier versions") {
                if let versions, versions.isEmpty {
                    Text("No earlier versions.").foregroundStyle(.secondary)
                }
                ForEach(versions ?? []) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.label ?? version.modified?.formatted(date: .abbreviated, time: .shortened) ?? version.id)
                            Text(details(version)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View", systemImage: "eye") { Task { await show(version) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                        Button("Restore") { restoring = version }
                            .buttonStyle(.borderless)
                            .disabled(!item.canWrite)
                    }
                }
            }
        }
        .overlay { if versions == nil && failure == nil { ProgressView() } }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
        .quickLookPreview($preview)
        .confirmationDialog("Restore this version?", isPresented: Binding(get: { restoring != nil },
                                                                         set: { if !$0 { restoring = nil } })) {
            Button("Restore") {
                guard let version = restoring else { return }
                Task { await restore(version) }
            }
        } message: {
            Text("The current contents are kept as a version, so this can be undone.")
        }
        .alert("Versions", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func details(_ version: FileVersion) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file)]
        if version.label != nil, let date = version.modified {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if let author = version.author { parts.append(author) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = model.repository?.client else { return }
        do {
            versions = try await client.versions(of: item)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func show(_ version: FileVersion) async {
        guard let client = model.repository?.client else { return }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Versions/\(item.fileID)-\(version.id)", directoryHint: .isDirectory)
            .appending(component: item.name)
        do {
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try await client.download(version, to: url)
            }
            preview = url
        } catch {
            failure = error.localizedDescription
        }
    }

    private func restore(_ version: FileVersion) async {
        guard let repository = model.repository else { return }
        do {
            try await repository.client.restore(version)
            if let parent = item.path.parent { _ = try? await repository.refresh(parent) }
            model.changed()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The server's trash bin: put things back, or delete them for good.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [TrashedItem]?
    @State private var deleting: TrashedItem?
    @State private var emptying = false
    @State private var failure: String?

    var body: some View {
        List {
            ForEach(items ?? []) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.displayItem.symbolName)
                        .font(.title2).foregroundStyle(item.displayItem.symbolColor)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text(details(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Restore") { Task { await restore(item) } }
                        .buttonStyle(.borderless)
                }
                .contextMenu {
                    Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore(item) } }
                    Button("Delete Permanently", systemImage: "trash", role: .destructive) { deleting = item }
                }
                #if os(iOS)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                }
                #endif
            }
        }
        .overlay {
            if items == nil && failure == nil {
                ProgressView()
            } else if items?.isEmpty == true {
                ContentUnavailableView("Trash Is Empty", systemImage: "trash",
                                       description: Text("Deleted files stay here until the server removes them."))
            }
        }
        .navigationTitle("Deleted Files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Empty Trash", role: .destructive) { emptying = true }
                    .disabled(items?.isEmpty ?? true)
            }
        }
        .refreshable { await load() }
        .task(id: model.revision) { await load() }
        .confirmationDialog(deleting.map { "Delete “\($0.name)” permanently?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                guard let item = deleting else { return }
                Task { await run { try await $0.deletePermanently(item) } }
            }
        } message: { Text("This can't be undone.") }
        .confirmationDialog("Empty the trash?", isPresented: $emptying, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { Task { await run { try await $0.emptyTrash() } } }
        } message: { Text("Everything in it is deleted permanently. This can't be undone.") }
        .alert("Deleted Files", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func details(_ item: TrashedItem) -> String {
        var parts: [String] = []
        if let deleted = item.deleted { parts.append("Deleted " + deleted.formatted(.relative(presentation: .named))) }
        let folder = item.originalLocation.parent ?? .root
        parts.append("from " + (folder.isRoot ? "Files" : folder.rawValue))
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = model.repository?.client else { return }
        do {
            items = try await client.trash()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func restore(_ item: TrashedItem) async {
        await run { try await $0.restore(item) }
        // Its folder shows it again; Finder, Files and Spotlight follow.
        await model.sync()
    }

    private func run(_ action: (NextcloudClient) async throws -> Void) async {
        guard let client = model.repository?.client else { return }
        do {
            try await action(client)
            model.changed()
        } catch {
            failure = error.localizedDescription
        }
        await load()
    }
}
