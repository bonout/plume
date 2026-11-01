import Foundation
import Observation
import OSLog
import PlumeKit

/// The app's state: the account, the repository, transfers in progress, and
/// the file being previewed.
@MainActor @Observable
final class AppModel {
    private(set) var credentials: Credentials?
    private(set) var repository: Repository?

    /// Uploads and downloads in progress, shown at the bottom of the window.
    private(set) var transfers: [Transfer] = []
    /// The local copy shown by Quick Look.
    var previewURL: URL?
    private(set) var opening: Set<RemoteItem.ID> = []
    /// Files opened in Plume from another app, waiting for a destination.
    var pendingImports: [URL] = []
    var errorMessage: String?
    var credentialsRevoked = false
    var lastServer = AppGroup.defaults.string(forKey: "lastServer") ?? ""
    /// Bumped when something changed on the server because of the app:
    /// visible folders reload.
    private(set) var revision = 0

    let thumbnails = ThumbnailCache()
    /// What the server offers and enforces (push, sharing rules…).
    private(set) var capabilities = ServerCapabilities()

    /// The Files browser's navigation stack (Spotlight results open in it).
    var path: [RemotePath] = DebugLaunch.initialPath
    /// The search, shared by every folder: it covers the whole account.
    var searchText = DebugLaunch.initialSearch
    /// Mac sidebar section.
    var section: Section = DebugLaunch.initialSection
    /// Every folder has been listed once: searches are answered locally.
    private(set) var indexComplete = AppGroup.defaults.bool(forKey: "indexComplete")

    enum Section: String, Hashable {
        case files, favorites, offline, trash
    }

    private let spotlight = SpotlightIndex()
    private var spotlightFeed: Task<Void, Never>?
    /// Push from the server and, on the Mac, the periodic sync.
    private var watchers: [Task<Void, Never>] = []
    private var syncing = false
    /// Uploads in progress and their overall progress, which keep the app
    /// running in the background (Background).
    private var uploadsInFlight = 0
    private var uploadProgress = Progress()

    struct Transfer: Identifiable {
        let id = UUID()
        let name: String
        let isUpload: Bool
        let progress: Progress
    }

    init() {
        #if DEBUG
        if DebugLaunch.resetAccount {
            AccountStore.remove()
            MetadataStore.removeAllDatabases()
            AppGroup.defaults.removeObject(forKey: "indexComplete")
            AppGroup.defaults.removeObject(forKey: "lastServer")
            lastServer = ""
        }
        #endif
        if let credentials = AccountStore.load() { activate(credentials) }
        #if DEBUG
        signInForTesting()
        #endif
    }

    #if DEBUG
    /// Debug builds only: signs in from launch arguments, for tests against
    /// a throwaway server (scripts/test-server.sh):
    ///   -PlumeTestServer http://127.0.0.1:8099 -PlumeTestUser admin -PlumeTestPassword …
    private func signInForTesting() {
        let defaults = UserDefaults.standard
        guard credentials == nil,
              let server = defaults.string(forKey: "PlumeTestServer").flatMap(URL.init(string:)),
              let user = defaults.string(forKey: "PlumeTestUser"),
              let password = defaults.string(forKey: "PlumeTestPassword") else { return }
        Task {
            do {
                let credentials = try await LoginFlow.complete(server: server, loginName: user, appPassword: password)
                // Without a provisioning profile (Mac build with no Apple
                // account in Xcode) the keychain refuses: stay signed in for
                // this run only.
                do { try signIn(credentials) } catch { activate(credentials) }
            } catch {
                report(error)
            }
        }
    }
    #endif

    // MARK: Account

    func signIn(_ credentials: Credentials) throws {
        try AccountStore.save(credentials)
        lastServer = credentials.account.server.absoluteString
        AppGroup.defaults.set(lastServer, forKey: "lastServer")
        activate(credentials)
    }

    private func activate(_ credentials: Credentials) {
        guard let store = try? MetadataStore.named("app") else {
            errorMessage = "The local database can't be opened."
            return
        }
        self.credentials = credentials
        // Every change the repository sees goes to Spotlight, in order.
        let (changes, feed) = AsyncStream.makeStream(of: Repository.Changes.self)
        repository = Repository(client: NextcloudClient(credentials: credentials), store: store,
                                onChange: { feed.yield($0) })
        spotlightFeed = Task { [spotlight] in
            for await batch in changes { await spotlight.apply(batch) }
        }
        Task {
            await FileProviderControl.register()
            await DebugLaunch.apply(to: self)
            await sync()
        }
        watch()
    }

    /// Follows the server: notify_push when it has it (a change anywhere
    /// syncs within seconds), and on the Mac a sync every minute whether a
    /// window is open or not (the app keeps running without one).
    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        #if os(macOS)
        watchers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sync()
            }
        })
        #endif
        watchers.append(Task { [weak self] in
            var delay: Duration = .seconds(5)
            while !Task.isCancelled {
                guard let self, let client = self.repository?.client else { return }
                if let capabilities = try? await client.capabilities() {
                    self.capabilities = capabilities
                }
                guard let socket = self.capabilities.pushURL else { return }
                do {
                    for try await _ in client.fileChanges(at: socket) {
                        delay = .seconds(5)
                        // Changes come in bursts: one sync for each.
                        try await Task.sleep(for: .seconds(2))
                        await self.sync()
                        self.revision += 1
                    }
                } catch PlumeError.unauthorized {
                    return
                } catch {}
                // Dropped (network, server restart, app suspended): retry,
                // waiting longer each time, up to five minutes.
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(300))
            }
        })
    }

    func signOut() async {
        watchers.forEach { $0.cancel() }
        watchers = []
        if let repository {
            try? await repository.client.revokeAppPassword()
            repository.store.removeAll()
            repository.files.removeAll()
        }
        await FileProviderControl.removeAll()
        spotlightFeed?.cancel()
        await spotlight.removeAll()
        AccountStore.remove()
        AppGroup.defaults.removeObject(forKey: "indexComplete")
        AppGroup.defaults.removeObject(forKey: "lastShareFolder")
        AppGroup.pinnedPaths = []
        MetadataStore.removeAllDatabases()
        try? FileManager.default.removeItem(at: AppGroup.cachesURL)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "Versions"))
        credentialsRevoked = false
        capabilities = ServerCapabilities()
        indexComplete = false
        credentials = nil
        repository = nil
        transfers = []
        path = []
        searchText = ""
    }

    // MARK: Sync

    /// Sends what the share extension left, mirrors the tree (for search and
    /// Spotlight), refreshes offline files, and tells Finder / Files to look
    /// for changes. Run when the app becomes active and every minute while
    /// it is; once the tree is known, one request when nothing changed.
    func sync() async {
        guard let repository, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let outbox = Outbox()
        if !outbox.pending().isEmpty, await outbox.sendAll(with: repository) > 0 {
            revision += 1
        }
        if (try? await repository.syncTree()) != nil {
            indexComplete = true
            AppGroup.defaults.set(true, forKey: "indexComplete")
            if await !spotlight.isCurrent {
                await spotlight.reindex(repository.store.subtree(of: .root))
            }
        }
        await repository.syncAllOffline()
        AppGroup.pinnedPaths = Set(repository.store.pinnedPaths())
        repository.files.trimCache()
        FileProviderControl.signalChanges()
    }

    // MARK: Files

    /// Shows an item found by Spotlight: its folder, or the file in Quick
    /// Look over its folder.
    func reveal(fileID: String) {
        guard let item = repository?.store.item(fileID: fileID) else { return }
        searchText = ""
        section = .files
        if item.isDirectory {
            path = item.path.ancestry
        } else {
            path = (item.path.parent ?? .root).ancestry
            open(item)
        }
    }

    /// Downloads if needed, then shows the file in Quick Look.
    func open(_ item: RemoteItem) {
        guard let repository, !item.isDirectory else { return }
        guard !opening.contains(item.id) else { return }
        if let url = repository.files.existingCopy(of: item) {
            previewURL = url
            return
        }
        opening.insert(item.id)
        Task {
            defer { opening.remove(item.id) }
            if let url = await localCopy(of: item) { previewURL = url }
        }
    }

    /// A current local copy, downloaded with a visible progress if needed.
    func localCopy(of item: RemoteItem) async -> URL? {
        guard let repository else { return nil }
        if let url = repository.files.existingCopy(of: item) { return url }
        let transfer = Transfer(name: item.name, isUpload: false, progress: Progress(totalUnitCount: 100))
        transfers.append(transfer)
        defer { transfers.removeAll { $0.id == transfer.id } }
        do {
            return try await repository.localCopy(of: item, progress: transfer.progress)
        } catch {
            report(error)
            return nil
        }
    }

    /// Uploads local files (picked, dropped, or opened in Plume) into
    /// `folder`. They go through the outbox, so an interrupted upload is
    /// retried at the next sync.
    func upload(_ urls: [URL], into folder: RemotePath) {
        guard let repository else { return }
        let outbox = Outbox()
        var jobs: [Outbox.Job] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                jobs.append(try outbox.enqueue(url, destination: folder))
            } catch {
                report(error)
            }
        }
        for job in jobs {
            let transfer = Transfer(name: job.name, isUpload: true, progress: Progress(totalUnitCount: 100))
            transfers.append(transfer)
            uploadStarted(transfer.progress)
            Task {
                defer {
                    transfers.removeAll { $0.id == transfer.id }
                    uploadEnded()
                }
                do {
                    try await outbox.send(job, with: repository, progress: transfer.progress)
                    revision += 1
                    FileProviderControl.signalChanges()
                } catch {
                    report(error)
                }
            }
        }
    }

    private func uploadStarted(_ progress: Progress) {
        if uploadsInFlight == 0 { uploadProgress = Progress(totalUnitCount: 0) }
        uploadsInFlight += 1
        uploadProgress.totalUnitCount += 100
        uploadProgress.addChild(progress, withPendingUnitCount: 100)
        Background.shared.uploadsChanged(count: uploadsInFlight, progress: uploadProgress)
    }

    private func uploadEnded() {
        uploadsInFlight -= 1
        Background.shared.uploadsChanged(count: uploadsInFlight, progress: uploadProgress)
    }

    /// Something changed on the server because of the app: visible lists
    /// reload, Finder and Files look for changes.
    func changed() {
        revision += 1
        FileProviderControl.signalChanges()
    }

    func perform(_ action: @escaping (Repository) async throws -> Void) {
        guard let repository else { return }
        Task {
            do {
                try await action(repository)
                revision += 1
                FileProviderControl.signalChanges()
            } catch {
                report(error)
            }
        }
    }

    func toggleOffline(_ item: RemoteItem) {
        guard let repository else { return }
        if repository.store.pinnedPaths().contains(item.path) {
            repository.removeFromOffline(item)
            publishPins()
            revision += 1
        } else {
            let transfer = Transfer(name: item.name, isUpload: false, progress: Progress(totalUnitCount: 100))
            transfers.append(transfer)
            Task {
                defer { transfers.removeAll { $0.id == transfer.id } }
                do {
                    try await repository.makeAvailableOffline(item)
                } catch {
                    report(error)
                }
                publishPins()
                revision += 1
            }
        }
    }

    /// Finder keeps pinned items downloaded too (File Provider).
    private func publishPins() {
        guard let repository else { return }
        AppGroup.pinnedPaths = Set(repository.store.pinnedPaths())
        FileProviderControl.signalChanges()
    }

    func isPinned(_ item: RemoteItem) -> Bool {
        _ = revision
        return repository?.store.pinnedPaths().contains(item.path) ?? false
    }

    func isAvailableOffline(_ item: RemoteItem) -> Bool {
        guard let repository else { return false }
        return item.isDirectory ? isPinned(item) : repository.files.isAvailableOffline(item)
    }

    func copyLink(_ item: RemoteItem) {
        perform { repository in
            let url = try await repository.client.publicLink(for: item.path)
            await MainActor.run { Platform.copyToPasteboard(url.absoluteString) }
        }
    }

    func report(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if error as? PlumeError == .unauthorized {
            credentialsRevoked = true
            return
        }
        Logger(subsystem: "Plume", category: "App").error("\(error, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}
