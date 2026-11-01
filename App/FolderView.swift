import PlumeKit
import PlumeUI
import SwiftUI
import UniformTypeIdentifiers

/// One folder: shown from the local mirror at once, then refreshed from
/// the server.
struct FolderView: View {
    let path: RemotePath
    @Environment(AppModel.self) private var model

    @State private var items: [RemoteItem] = []
    @State private var loaded = false
    @State private var offlineError: String?
    @State private var importing = false
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.searchText.isEmpty {
                SearchResults(term: model.searchText)
            } else {
                ItemList(items: items)
                    .overlay {
                        if loaded && items.isEmpty {
                            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                                   description: Text("Drop files here or use the + button."))
                        }
                    }
            }
        }
        .navigationTitle(path.isRoot ? "Files" : path.name)
        .searchable(text: $model.searchText, prompt: "Search all files")
        .refreshable { await refresh() }
        .task(id: model.revision) { await refresh() }
        .safeAreaInset(edge: .top) {
            if let offlineError {
                Label(offlineError, systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Upload Files…", systemImage: "arrow.up.doc") { importing = true }
                    Button("New Folder", systemImage: "folder.badge.plus") { creatingFolder = true }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.upload(urls, into: path) }
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Create") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                folderName = ""
                guard !name.isEmpty else { return }
                model.perform { _ = try await $0.createFolder(named: name, in: path) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.upload(files, into: path)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func refresh() async {
        guard let repository = model.repository else { return }
        if !loaded {
            items = repository.store.children(of: path)
            loaded = !items.isEmpty
        }
        do {
            items = try await repository.refresh(path).children
            offlineError = nil
        } catch PlumeError.offline {
            offlineError = "Offline: showing the last known contents."
        } catch {
            model.report(error)
        }
        loaded = true
    }
}

/// Results from the local mirror, at each keystroke. Until every folder has
/// been listed once (first run), the server's search completes them.
struct SearchResults: View {
    let term: String
    @Environment(AppModel.self) private var model
    @State private var items: [RemoteItem] = []
    @State private var searching = false

    var body: some View {
        ItemList(items: items, showsLocation: true)
            .overlay {
                if items.isEmpty && !searching { ContentUnavailableView.search(text: term) }
            }
            .task(id: "\(term)|\(model.repository != nil)|\(model.indexComplete)") {
                guard let repository = model.repository else { return }
                items = repository.store.search(term)
                guard !model.indexComplete else { return }
                searching = true
                defer { searching = false }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let remote = try? await repository.client.search(term) else { return }
                let local = Set(items.map(\.path))
                items += remote.filter { !local.contains($0.path) }
            }
    }
}

struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [RemoteItem] = []

    var body: some View {
        ItemList(items: items, showsLocation: true)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No Favorites", systemImage: "star",
                                           description: Text("Mark files and folders as favorites to find them here."))
                }
            }
            .navigationTitle("Favorites")
            .refreshable { await load() }
            .task(id: model.revision) { await load() }
    }

    private func load() async {
        guard let repository = model.repository else { return }
        items = repository.store.favorites()
        guard let remote = try? await repository.client.favorites() else { return }
        for item in remote { repository.store.upsert(item) }
        items = remote.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct OfflineView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [RemoteItem] = []

    var body: some View {
        ItemList(items: items, showsLocation: true)
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Nothing Offline", systemImage: "arrow.down.circle",
                                           description: Text("Make files or folders available offline to open them without a connection."))
                }
            }
            .navigationTitle("Offline")
            .task(id: model.revision) {
                guard let store = model.repository?.store else { return }
                items = store.pinnedPaths().compactMap { store.item(at: $0) }
            }
    }
}
