import Foundation

/// Files waiting to be uploaded, kept in the group container. The share
/// extension copies what it receives here first, so that nothing is lost if
/// the system closes it before the upload ends: the app sends what is left
/// the next time it runs.
public struct Outbox: Sendable {
    public struct Job: Codable, Sendable, Identifiable, Hashable {
        public var id: UUID
        public var name: String
        public var destination: RemotePath
        public var created: Date
    }

    public let root: URL

    public init(root: URL = AppGroup.containerURL.appending(path: "Outbox", directoryHint: .isDirectory)) {
        self.root = root
    }

    /// Copies (or moves) `file` into the outbox, to be uploaded into
    /// `destination`.
    public func enqueue(_ file: URL, name: String? = nil, destination: RemotePath, move: Bool = false) throws -> Job {
        let job = Job(id: UUID(), name: sanitized(name ?? file.lastPathComponent), destination: destination,
                      created: Date())
        let folder = folder(of: job)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if move {
            try FileManager.default.moveItem(at: file, to: fileURL(of: job))
        } else {
            try FileManager.default.copyItem(at: file, to: fileURL(of: job))
        }
        try JSONEncoder().encode(job).write(to: folder.appending(path: "job.json"), options: .atomic)
        return job
    }

    /// A folder in the group container for files received but not yet
    /// given a destination (same volume as the outbox: moves are instant).
    public func makeStagingFolder() throws -> URL {
        let url = root.deletingLastPathComponent()
            .appending(path: "Staging/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func pending() -> [Job] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? JSONDecoder().decode(Job.self, from: Data(contentsOf: $0.appending(path: "job.json"))) }
            .sorted { $0.created < $1.created }
    }

    public func fileURL(of job: Job) -> URL {
        folder(of: job).appending(component: job.name)
    }

    public func remove(_ job: Job) {
        try? FileManager.default.removeItem(at: folder(of: job))
    }

    /// Uploads one job and removes it once on the server.
    @discardableResult
    public func send(_ job: Job, with repository: Repository, progress: Progress? = nil) async throws -> RemoteItem {
        let item = try await repository.upload(fileURL(of: job), named: job.name, into: job.destination,
                                               progress: progress)
        remove(job)
        return item
    }

    /// Sends everything pending; returns how many went through.
    public func sendAll(with repository: Repository) async -> Int {
        var sent = 0
        for job in pending() {
            if (try? await send(job, with: repository)) != nil { sent += 1 }
        }
        return sent
    }

    private func folder(of job: Job) -> URL {
        root.appending(path: job.id.uuidString, directoryHint: .isDirectory)
    }

    private func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }
}
