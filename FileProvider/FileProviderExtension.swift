@preconcurrency import FileProvider
import Foundation
import PlumeKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Puts the Nextcloud files in Finder and the Files app, the way iCloud
/// Drive is: placeholders listed from the server, contents downloaded when
/// opened (or kept downloaded when the user asks), and anything another app
/// saves there uploaded. Items are identified by their Nextcloud file id,
/// which survives renames and moves.
///
/// The extension keeps its own metadata store: it compares the server
/// against what *it* has reported to the system, independently of the app.
/// Its state is immutable once created, hence `@unchecked Sendable`.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    let domain: NSFileProviderDomain
    private let repository: Repository?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        if let credentials = AccountStore.load(),
           let store = try? MetadataStore.named("fileprovider-\(domain.identifier.rawValue)") {
            repository = Repository(client: NextcloudClient(credentials: credentials), store: store)
        } else {
            repository = nil
        }
        super.init()
    }

    func invalidate() {}

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform { (repository: Repository) async throws -> FileProviderItem in
            let remote = repository.store.upsert(
                try await repository.client.item(at: try self.path(of: identifier, in: repository)))
            return self.providerItem(remote, in: repository)
        } done: { item, error in completionHandler(item, error) }
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let manager = NSFileProviderManager(for: domain)
        perform { (repository: Repository) async throws -> (URL, FileProviderItem) in
            let remote = repository.store.upsert(
                try await repository.client.item(at: try self.path(of: itemIdentifier, in: repository)))
            guard let temporaryFolder = try manager?.temporaryDirectoryURL() else {
                throw NSFileProviderError(.cannotSynchronize)
            }
            let destination = temporaryFolder.appending(path: UUID().uuidString)
            if let copy = repository.files.existingCopy(of: remote) {
                // Already downloaded by the app: a copy-on-write clone.
                try FileManager.default.copyItem(at: copy, to: destination)
                progress.completedUnitCount = 100
            } else {
                try await repository.client.download(remote.path, to: destination, progress: progress)
            }
            return (destination, self.providerItem(remote, in: repository))
        } done: { result, error in completionHandler(result?.0, result?.1, error) }
        return progress
    }

    // MARK: Changes from the device

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
    -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let template = SendableItem(itemTemplate)
        let contents = url
        perform { (repository: Repository) async throws -> FileProviderItem in
            let template = template.item
            if Self.isExcluded(template.filename) { throw NSFileProviderError(.excludedFromSync) }
            let parent = try self.path(of: template.parentItemIdentifier, in: repository)
            let path = parent.appending(template.filename)
            var remote: RemoteItem
            if template.contentType == .folder {
                do {
                    remote = try await repository.client.createFolder(at: path)
                } catch PlumeError.alreadyExists where options.contains(.mayAlreadyExist) {
                    remote = try await repository.client.item(at: path)
                }
            } else if template.contentType == .symbolicLink || template.contentType == .aliasFile {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            } else {
                let source = try contents ?? Self.emptyFile()
                do {
                    remote = try await repository.client.upload(
                        source, to: path, overwrite: false,
                        modified: fields.contains(.contentModificationDate) ? template.contentModificationDate ?? nil : nil,
                        progress: progress)
                } catch PlumeError.alreadyExists where options.contains(.mayAlreadyExist) {
                    // Reimport after the system lost track: the existing item wins.
                    remote = try await repository.client.item(at: path)
                }
            }
            remote = repository.store.upsert(remote)
            return self.providerItem(remote, in: repository)
        } done: { item, error in completionHandler(item, [], false, error) }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void)
    -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let changed = SendableItem(item)
        perform { (repository: Repository) async throws -> FileProviderItem in
            let item = changed.item
            var path = try self.path(of: item.itemIdentifier, in: repository)
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parent = try self.path(of: item.parentItemIdentifier, in: repository)
                let destination = parent.appending(item.filename)
                if destination != path {
                    _ = try await repository.client.move(path, to: destination)
                    repository.store.move(path, to: destination)
                    path = destination
                }
            }
            if changedFields.contains(.contents), let newContents {
                _ = try await repository.client.upload(
                    newContents, to: path, overwrite: true,
                    modified: item.contentModificationDate ?? nil, progress: progress)
            }
            // Other fields (tags, last used date, favorite rank) stay local.
            let remote = repository.store.upsert(try await repository.client.item(at: path))
            return self.providerItem(remote, in: repository)
        } done: { item, error in completionHandler(item, [], false, error) }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform { (repository: Repository) async throws -> Void in
            let path: RemotePath
            do {
                path = try self.path(of: identifier, in: repository)
            } catch {
                return  // Unknown here: nothing to delete.
            }
            // Nextcloud moves it to its trash bin, where it can be restored.
            try await repository.client.delete(path)
            repository.store.remove(path)
        } done: { _, error in completionHandler(error) }
        return progress
    }

    // MARK: Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws
    -> NSFileProviderEnumerator {
        guard let repository else { throw NSFileProviderError(.notAuthenticated) }
        if containerItemIdentifier == .workingSet {
            return Enumerator(extension: self, repository: repository, folder: nil)
        }
        if containerItemIdentifier == .trashContainer {
            return EmptyEnumerator()
        }
        return Enumerator(extension: self, repository: repository,
                          folder: try path(of: containerItemIdentifier, in: repository))
    }

    // MARK: Helpers

    func path(of identifier: NSFileProviderItemIdentifier, in repository: Repository) throws -> RemotePath {
        if identifier == .rootContainer { return .root }
        guard let item = repository.store.item(fileID: identifier.rawValue) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return item.path
    }

    func providerItem(_ remote: RemoteItem, in repository: Repository) -> FileProviderItem {
        FileProviderItem(remote, parent: parentIdentifier(of: remote, in: repository),
                         isPinned: AppGroup.pinnedPaths.contains(remote.path),
                         nextcloud: repository.client.account.isNextcloud)
    }

    func parentIdentifier(of remote: RemoteItem, in repository: Repository) -> NSFileProviderItemIdentifier {
        guard let parent = remote.path.parent, !parent.isRoot,
              let item = repository.store.item(at: parent), !item.fileID.isEmpty
        else { return .rootContainer }
        return NSFileProviderItemIdentifier(item.fileID)
    }

    /// Finder's and the system's own files never go to the server.
    static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".localized"
    }

    static func emptyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: url)
        return url
    }

    /// Runs `body` in a task and calls back once, with errors the system
    /// understands.
    private func perform<T>(_ body: @escaping @Sendable (Repository) async throws -> T,
                                     done: @escaping (T?, Error?) -> Void) {
        let done = UncheckedBox(done)
        guard let repository else {
            done.value(nil, NSFileProviderError(.notAuthenticated))
            return
        }
        Task {
            do {
                let value = try await body(repository)
                done.value(value, nil)
            } catch {
                done.value(nil, Self.providerError(error))
            }
        }
    }

    static func providerError(_ error: Error) -> Error {
        switch error {
        case let error as PlumeError:
            switch error {
            case .notSignedIn, .unauthorized: return NSFileProviderError(.notAuthenticated)
            case .notFound: return NSFileProviderError(.noSuchItem)
            case .alreadyExists: return NSFileProviderError(.filenameCollision)
            case .insufficientStorage: return NSFileProviderError(.insufficientQuota)
            case .offline, .maintenance, .untrustedCertificate, .notNextcloud, .notWebDAV:
                return NSFileProviderError(.serverUnreachable)
            case .unsupported: return NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            case .forbidden: return CocoaError(.fileWriteNoPermission)
            case .conflict, .http, .invalidResponse, .refused: return NSFileProviderError(.cannotSynchronize)
            }
        case let error as URLError where error.code != .cancelled:
            return NSFileProviderError(.serverUnreachable)
        default:
            return error
        }
    }
}

/// The system's item protocols and callbacks predate Sendable; each is only
/// used by one task at a time.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct SendableItem: @unchecked Sendable {
    let item: NSFileProviderItem
    init(_ item: NSFileProviderItem) { self.item = item }
}

final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}

// MARK: - Thumbnails

/// Finder and the Files app show the server's thumbnails (photos, PDFs,
/// videos, Office documents…) before anything is downloaded.
extension FileProviderExtension: NSFileProviderThumbnailing {
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let each = UncheckedBox(perThumbnailCompletionHandler)
        let done = UncheckedBox(completionHandler)
        guard let repository else {
            completionHandler(NSFileProviderError(.notAuthenticated))
            return progress
        }
        // The server renders square thumbnails; ask for the larger side,
        // within what it generates.
        let pixels = min(1024, max(64, Int(max(size.width, size.height))))
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for identifier in itemIdentifiers {
                    group.addTask {
                        let item = repository.store.item(fileID: identifier.rawValue)
                        var data: Data?
                        if let item, item.hasPreview, !item.isDirectory {
                            data = try? await repository.client.preview(of: item, size: pixels)
                        }
                        if Task.isCancelled {
                            each.value(identifier, nil, CocoaError(.userCancelled))
                        } else {
                            each.value(identifier, data, nil)
                        }
                        progress.completedUnitCount += 1
                    }
                }
            }
            done.value(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

// MARK: - Actions in Finder and the Files app

/// The actions declared under NSExtensionFileProviderActions (project.yml),
/// shown in the item's menu.
extension FileProviderExtension: NSFileProviderCustomAction {
    enum Action: String {
        case copyLink = "plume.copyLink"
        case favorite = "plume.favorite"
        case unfavorite = "plume.unfavorite"
    }

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let manager = NSFileProviderManager(for: domain)
        perform { (repository: Repository) async throws -> Void in
            guard let action = Action(rawValue: actionIdentifier.rawValue) else {
                throw CocoaError(.featureUnsupported)
            }
            let items = try itemIdentifiers.map { identifier -> RemoteItem in
                guard identifier != .rootContainer, let item = repository.store.item(fileID: identifier.rawValue) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                return item
            }
            switch action {
            case .copyLink:
                var links: [String] = []
                for item in items {
                    links.append(try await repository.client.publicLink(for: item.path).absoluteString)
                    progress.completedUnitCount += 1
                }
                Pasteboard.copy(links.joined(separator: "\n"))
            case .favorite, .unfavorite:
                for item in items {
                    _ = try await repository.setFavorite(action == .favorite, for: item)
                    progress.completedUnitCount += 1
                }
                // The menus follow the new state.
                try? await manager?.signalEnumerator(for: .workingSet)
            }
        } done: { _, error in completionHandler(error) }
        return progress
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
