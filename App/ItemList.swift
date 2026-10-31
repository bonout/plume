import PlumeKit
import PlumeUI
import SwiftUI

/// A list of files and folders with their actions: open (tap, double-click,
/// space for Quick Look), and a context menu.
struct ItemList: View {
    let items: [RemoteItem]
    var showsLocation = false

    @Environment(AppModel.self) private var model
    @Environment(\.openFolder) private var openFolder
    @State private var selection: Set<RemoteItem.ID> = []
    @State private var renaming: RemoteItem?
    @State private var newName = ""
    @State private var deleting: RemoteItem?

    var body: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                ItemRow(item: item, showsLocation: showsLocation)
                    .tag(item.id)
                    #if os(iOS)
                    .swipeActions(edge: .trailing) {
                        if item.canDelete {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(model.isPinned(item) ? "Remove Offline" : "Offline",
                               systemImage: "arrow.down.circle") { model.toggleOffline(item) }
                            .tint(.blue)
                    }
                    #endif
            }
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            if let item = item(ids) { menu(for: item) }
        } primaryAction: { ids in
            if let item = item(ids) { open(item) }
        }
        #if os(macOS)
        .onKeyPress(.space) {
            guard let item = item(selection), !item.isDirectory else { return .ignored }
            model.open(item)
            return .handled
        }
        .onDeleteCommand {
            if let item = item(selection), item.canDelete { deleting = item }
        }
        #endif
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let item = renaming else { return }
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != item.name else { return }
                model.perform { _ = try await $0.rename(item, to: name) }
            }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let item = deleting else { return }
                model.perform { try await $0.delete(item) }
            }
        } message: {
            Text("It goes to the server's trash bin, where it can be restored.")
        }
    }

    private func item(_ ids: Set<RemoteItem.ID>) -> RemoteItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return items.first { $0.id == id }
    }

    private func open(_ item: RemoteItem) {
        if item.isDirectory {
            openFolder(item.path)
        } else {
            model.open(item)
        }
    }

    @ViewBuilder
    private func menu(for item: RemoteItem) -> some View {
        Button(item.isDirectory ? "Open" : "Quick Look", systemImage: item.isDirectory ? "folder" : "eye") { open(item) }
        #if os(macOS)
        Button("Open With Default App", systemImage: "arrow.up.forward.app") { openInFinder(item, reveal: false) }
        Button("Show in Finder", systemImage: "finder") { openInFinder(item, reveal: true) }
        #endif
        if showsLocation, let parent = item.path.parent {
            Button("Show Enclosing Folder", systemImage: "folder") { openFolder(parent) }
        }
        Divider()
        Button(model.isPinned(item) ? "Remove from Offline" : "Make Available Offline",
               systemImage: model.isPinned(item) ? "arrow.down.circle.fill" : "arrow.down.circle") {
            model.toggleOffline(item)
        }
        Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: item.isFavorite ? "star.slash" : "star") {
            model.perform { _ = try await $0.setFavorite(!item.isFavorite, for: item) }
        }
        Divider()
        Button("Copy Public Link", systemImage: "link") { model.copyLink(item) }
        if !item.isDirectory {
            Button("Share…", systemImage: "square.and.arrow.up") {
                Task { if let url = await model.localCopy(of: item) { Platform.share(url) } }
            }
        }
        Divider()
        if item.canRename {
            Button("Rename…", systemImage: "pencil") {
                newName = item.name
                renaming = item
            }
        }
        if item.canDelete {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
        }
    }

    #if os(macOS)
    private func openInFinder(_ item: RemoteItem, reveal: Bool) {
        Task {
            if let url = await FileProviderControl.userVisibleURL(for: item) {
                Platform.openInFinder(url, reveal: reveal)
            } else if !reveal, let url = await model.localCopy(of: item) {
                // Finder doesn't know the item yet: a read-only copy.
                NSWorkspace.shared.open(url)
            }
        }
    }
    #endif
}

struct ItemRow: View {
    let item: RemoteItem
    var showsLocation = false
    @Environment(AppModel.self) private var model
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(showsLocation ? location : item.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isFavorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            if model.isAvailableOffline(item) {
                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Available offline")
            }
            if item.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .task(id: item.etag) {
            guard item.hasPreview, let client = model.repository?.client else { return }
            thumbnail = model.thumbnails.cached(item)
            if thumbnail == nil { thumbnail = await model.thumbnails.image(for: item, client: client) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable().scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(.rect(cornerRadius: 6))
        } else {
            Image(systemName: item.symbolName)
                .font(.title2)
                .foregroundStyle(item.symbolColor)
        }
    }

    private var location: String {
        let parent = item.path.parent ?? .root
        return parent.isRoot ? "Files" : parent.rawValue
    }
}
