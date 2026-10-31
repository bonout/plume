import PlumeKit
import PlumeUI
import QuickLook
import SwiftUI

@main
struct PlumeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 980, height: 640)
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 460)
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if model.repository != nil {
                MainView()
            } else {
                LoginView()
            }
        }
        .quickLookPreview($model.previewURL)
        .onOpenURL { url in
            // A file opened in Plume from another app (or dropped on the
            // Dock icon): ask where to put it.
            if url.isFileURL { model.pendingImports.append(url) }
        }
        .sheet(isPresented: Binding(get: { !model.pendingImports.isEmpty && model.repository != nil },
                                    set: { if !$0 { model.pendingImports = [] } })) {
            if let repository = model.repository {
                FolderPicker(repository: repository,
                             title: model.pendingImports.count == 1
                                ? "Save “\(model.pendingImports[0].lastPathComponent)”"
                                : "Save \(model.pendingImports.count) Files",
                             onPick: { folder in
                                 model.upload(model.pendingImports, into: folder)
                                 model.pendingImports = []
                             },
                             onCancel: { model.pendingImports = [] })
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 460)
                #endif
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        #if os(macOS)
        .task { await DebugLaunch.takeSnapshot() }
        #endif
        .task(id: scenePhase) {
            // While the app is in front: sync now, then every minute.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.sync()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

struct MainView: View {
    enum Section: String, Hashable {
        case files, favorites, offline, settings
    }

    @Environment(AppModel.self) private var model
    @State private var selection = DebugLaunch.initialTab

    var body: some View {
        TabView(selection: $selection) {
            Tab("Files", systemImage: "folder", value: .files) {
                BrowserStack(initialPath: DebugLaunch.initialPath) { FolderView(path: .root) }
            }
            Tab("Favorites", systemImage: "star", value: .favorites) {
                BrowserStack { FavoritesView() }
            }
            Tab("Offline", systemImage: "arrow.down.circle", value: .offline) {
                BrowserStack { OfflineView() }
            }
            #if os(iOS)
            Tab("Settings", systemImage: "gear", value: .settings) {
                NavigationStack { SettingsView() }
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        .safeAreaInset(edge: .bottom) {
            if !model.transfers.isEmpty { TransferBar() }
        }
    }
}

/// A navigation stack whose pushed screens are folders.
struct BrowserStack<Root: View>: View {
    @ViewBuilder let root: () -> Root
    @State private var path: [RemotePath]

    init(initialPath: [RemotePath] = [], @ViewBuilder root: @escaping () -> Root) {
        self.root = root
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: RemotePath.self) { FolderView(path: $0) }
        }
        .environment(\.openFolder, OpenFolderAction { path.append($0) })
    }
}

struct OpenFolderAction {
    let action: (RemotePath) -> Void
    init(_ action: @escaping (RemotePath) -> Void) { self.action = action }
    func callAsFunction(_ path: RemotePath) { action(path) }
}

extension EnvironmentValues {
    @Entry var openFolder = OpenFolderAction { _ in }
}

struct TransferBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.transfers) { transfer in
                HStack(spacing: 10) {
                    Image(systemName: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transfer.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        ProgressView(transfer.progress).labelsHidden()
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .frame(maxWidth: 520)
    }
}
