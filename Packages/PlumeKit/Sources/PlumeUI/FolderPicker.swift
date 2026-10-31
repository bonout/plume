import PlumeKit
import SwiftUI

/// Picks a destination folder: used by the share extension and by the app
/// when files are opened in it from elsewhere. Shows the local listing at
/// once, then the server's.
public struct FolderPicker: View {
    let repository: Repository
    let title: String
    let actionTitle: String
    let onPick: (RemotePath) -> Void
    let onCancel: () -> Void

    @State private var path: [RemotePath] = []

    /// Opens on `initial` (the last folder used, typically), with its
    /// parents in the back stack.
    public init(repository: Repository, title: String, actionTitle: String = "Save Here", initial: RemotePath = .root,
                onPick: @escaping (RemotePath) -> Void, onCancel: @escaping () -> Void) {
        self.repository = repository
        var chain: [RemotePath] = []
        var current: RemotePath? = initial
        while let folder = current, !folder.isRoot {
            chain.insert(folder, at: 0)
            current = folder.parent
        }
        _path = State(initialValue: chain)
        self.title = title
        self.actionTitle = actionTitle
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack(path: $path) {
            FolderPickerList(repository: repository, folder: .root)
                .navigationDestination(for: RemotePath.self) { folder in
                    FolderPickerList(repository: repository, folder: folder)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(actionTitle) { onPick(path.last ?? .root) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .navigationTitle(title)
    }
}

private struct FolderPickerList: View {
    let repository: Repository
    let folder: RemotePath

    @State private var folders: [RemoteItem] = []
    @State private var error: String?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
            }
            ForEach(folders) { item in
                NavigationLink(value: item.path) {
                    Label(item.name, systemImage: "folder.fill")
                }
            }
        }
        .overlay {
            if folders.isEmpty && error == nil {
                ContentUnavailableView("No Folders", systemImage: "folder",
                                       description: Text("Files will be saved in \(folder.isRoot ? "your files" : folder.name)."))
            }
        }
        .navigationTitle(folder.isRoot ? "Files" : folder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Folder", systemImage: "folder.badge.plus") { showingNewFolder = true }
            }
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { Task { await createFolder() } }
        }
        .task(id: folder) { await load() }
    }

    private func load() async {
        folders = repository.store.children(of: folder).filter(\.isDirectory)
        do {
            let listing = try await repository.refresh(folder)
            folders = listing.children.filter(\.isDirectory)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        do {
            _ = try await repository.createFolder(named: name, in: folder)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
