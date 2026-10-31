import Foundation
import Observation
import PlumeKit
import UniformTypeIdentifiers

/// "Save to Plume" from any app's share sheet: the shared files are copied
/// into the group container, the user picks a folder, and they are uploaded
/// from the outbox (the app finishes the job if the extension is closed
/// first).
@MainActor @Observable
final class ShareModel {
    enum Phase {
        case loading
        case signedOut
        case picking
        case uploading
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var files: [URL] = []
    let progress = Progress(totalUnitCount: 100)
    let repository: Repository?
    private let outbox = Outbox()
    private let finish: @MainActor () -> Void

    /// Where the previous share went: the picker opens there.
    static let lastFolderKey = "lastShareFolder"
    var lastFolder: RemotePath { RemotePath(AppGroup.defaults.string(forKey: Self.lastFolderKey) ?? "") }

    init(providers: [NSItemProvider], finish: @escaping @MainActor () -> Void) {
        self.finish = finish
        if let credentials = AccountStore.load(), let store = try? MetadataStore.named("app") {
            repository = Repository(client: NextcloudClient(credentials: credentials), store: store)
        } else {
            repository = nil
        }
        let providers = UncheckedProviders(providers)
        Task { await load(providers) }
    }

    private func load(_ providers: UncheckedProviders) async {
        guard repository != nil else {
            phase = .signedOut
            return
        }
        do {
            let staging = try outbox.makeStagingFolder()
            var loaded: [URL] = []
            for provider in providers.value {
                if let url = try await Self.loadFile(from: provider, into: staging) { loaded.append(url) }
            }
            files = loaded
            phase = loaded.isEmpty ? .failed("Nothing to save: only files, photos and videos can be saved.") : .picking
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func save(to folder: RemotePath) {
        guard let repository else { return }
        AppGroup.defaults.set(folder.rawValue, forKey: Self.lastFolderKey)
        phase = .uploading
        Task {
            let jobs = files.compactMap { try? outbox.enqueue($0, destination: folder, move: true) }
            let total = jobs.count
            var failures = 0
            for job in jobs {
                let step = Progress(totalUnitCount: 100)
                progress.addChild(step, withPendingUnitCount: Int64(100 / max(total, 1)))
                do {
                    try await outbox.send(job, with: repository, progress: step)
                } catch {
                    failures += 1
                }
            }
            if failures == 0 {
                phase = .done
                try? await Task.sleep(for: .milliseconds(600))
                finish()
            } else {
                phase = .failed("\(failures) of \(total) files couldn't be sent yet. Plume will send them the next time it opens.")
            }
        }
    }

    func cancel() {
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        finish()
    }

    func close() { finish() }

    /// Copies the provider's file into `folder`, keeping its name when it
    /// has one.
    nonisolated private static func loadFile(from provider: NSItemProvider, into folder: URL) async throws -> URL? {
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) || $0.conforms(to: .package) })
        else { return nil }
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                var name = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty,
                   let ext = type.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? nil : url.pathExtension) {
                    name += "." + ext
                }
                let subfolder = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let destination = subfolder.appending(component: name.replacingOccurrences(of: "/", with: "-"))
                do {
                    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Item providers predate Sendable; they are read once, in order.
struct UncheckedProviders: @unchecked Sendable {
    let value: [NSItemProvider]
    init(_ value: [NSItemProvider]) { self.value = value }
}
