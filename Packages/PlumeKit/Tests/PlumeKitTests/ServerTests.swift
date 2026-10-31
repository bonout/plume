import Foundation
@testable import PlumeKit
import Synchronization
import Testing

/// Against a real Nextcloud, only when one is given (scripts/test-server.sh
/// starts a throwaway one in Docker):
///
///   PLUME_TEST_SERVER=http://127.0.0.1:8099 PLUME_TEST_USER=admin \
///   PLUME_TEST_PASSWORD=… swift test
enum TestServer {
    static var credentials: Credentials? {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["PLUME_TEST_SERVER"].flatMap(URL.init(string:)),
              let user = env["PLUME_TEST_USER"], let password = env["PLUME_TEST_PASSWORD"] else { return nil }
        return Credentials(account: Account(server: server, loginName: user, userID: user), appPassword: password)
    }
}

@Suite(.enabled(if: TestServer.credentials != nil, "PLUME_TEST_SERVER is not set"), .serialized)
struct ServerTests {

    let repository: Repository
    let base: RemotePath

    init() async throws {
        let credentials = try await LoginFlow.complete(
            server: TestServer.credentials!.account.server, loginName: TestServer.credentials!.account.loginName,
            appPassword: TestServer.credentials!.appPassword)
        let temp = FileManager.default.temporaryDirectory.appending(path: "plume-server-\(UUID().uuidString)")
        repository = Repository(
            client: NextcloudClient(credentials: credentials),
            store: try MetadataStore(url: temp.appending(path: "store.sqlite")),
            files: LocalFiles(container: temp, caches: temp.appending(path: "Caches")))
        base = RemotePath("Plume Tests \(UUID().uuidString.prefix(8))")
        _ = try await repository.client.createFolder(at: base)
    }

    /// Runs a test, then removes its folder whatever the outcome (a `defer`
    /// can't wait for the deletion, and the process would exit first).
    func inBase(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            try? await repository.client.delete(base)
            throw error
        }
        try await repository.client.delete(base)
    }

    func temporaryFile(_ name: String, bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        var content = [UInt8](repeating: 0, count: bytes)
        for index in stride(from: 0, to: bytes, by: 4096) { content[index] = UInt8(index / 4096 % 251) }
        try Data(content).write(to: url)
        return url
    }

    @Test func uploadListDownloadRenameDelete() async throws {
        try await inBase {
            let repository = repository
            let small = try temporaryFile("note.txt", bytes: 1000)
            let item = try await repository.upload(small, named: "Résumé #1.txt", into: base)
            #expect(item.size == 1000)
            #expect(!item.fileID.isEmpty)

            // Same name: never overwritten, numbered instead.
            let second = try await repository.upload(small, named: "Résumé #1.txt", into: base)
            #expect(second.name == "Résumé #1 2.txt")

            let listing = try await repository.refresh(base)
            #expect(listing.children.map(\.name) == ["Résumé #1 2.txt", "Résumé #1.txt"])

            let copy = try await repository.localCopy(of: item)
            #expect(try Data(contentsOf: copy) == Data(contentsOf: small))

            let renamed = try await repository.rename(item, to: "Renamed.txt")
            #expect(renamed.fileID == item.fileID)
            await #expect(throws: PlumeError.alreadyExists) {
                try await repository.rename(second, to: "Renamed.txt")
            }

            try await repository.delete(renamed)
            #expect(try await repository.refresh(base).children.map(\.name) == ["Résumé #1 2.txt"])
        }
    }

    @Test func chunkedUpload() async throws {
        try await inBase {
            let size = NextcloudClient.chunkSize * 2 + 12_345
            let big = try temporaryFile("big.bin", bytes: size)
            let progress = Progress(totalUnitCount: 100)
            let item = try await repository.upload(big, named: "big.bin", into: base, progress: progress)
            #expect(item.size == Int64(size))
            #expect(progress.fractionCompleted > 0.99)
            let copy = try await repository.localCopy(of: item)
            #expect(try Data(contentsOf: copy) == Data(contentsOf: big))
        }
    }

    @Test func changesFollowEtags() async throws {
        try await inBase {
            let repository = repository
            let sub = try await repository.createFolder(named: "Sub", in: base)
            _ = try await repository.changes(under: .root)
            _ = try await repository.refresh(base)
            _ = try await repository.refresh(sub.path)

            // Nothing moved.
            var changes = try await repository.changes(under: .root)
            #expect(changes.updated.isEmpty && changes.removed.isEmpty)

            // A file two levels down: found, along with the folders above it.
            let file = try temporaryFile("deep.txt", bytes: 10)
            try await repository.client.upload(file, to: sub.path.appending("deep.txt"), overwrite: false)
            changes = try await repository.changes(under: .root)
            #expect(changes.updated.contains { $0.path == sub.path.appending("deep.txt") })
            #expect(changes.updated.contains { $0.path == base })

            try await repository.client.delete(sub.path)
            changes = try await repository.changes(under: .root)
            #expect(Set(changes.removed.map(\.path)) == [sub.path, sub.path.appending("deep.txt")])
        }
    }

    @Test func searchFavoritesAndLinks() async throws {
        try await inBase {
            let repository = repository
            let file = try temporaryFile("x.pdf", bytes: 10)
            let unique = "plume-\(UUID().uuidString.prefix(6))"
            let item = try await repository.upload(file, named: "\(unique).pdf", into: base)

            let found = try await repository.client.search(unique)
            #expect(found.map(\.path) == [item.path])

            _ = try await repository.setFavorite(true, for: item)
            #expect(try await repository.client.favorites().contains { $0.path == item.path })

            let link = try await repository.client.publicLink(for: item.path)
            #expect(link.absoluteString.contains("/s/"))
            #expect(try await repository.client.publicLink(for: item.path) == link)
        }
    }

    @Test func offlineFolder() async throws {
        try await inBase {
            let repository = repository
            let folder = try await repository.createFolder(named: "Trip", in: base)
            let file = try temporaryFile("a.jpg", bytes: 50)
            let photo = try await repository.upload(file, named: "a.jpg", into: folder.path)
            try await repository.makeAvailableOffline(folder)
            #expect(repository.files.isAvailableOffline(photo))

            repository.removeFromOffline(folder)
            #expect(!repository.files.isAvailableOffline(photo))
            #expect(repository.files.existingCopy(of: photo) != nil)
        }
    }

    @Test func syncTreeMirrorsEverythingAndReportsChanges() async throws {
        let collected = Mutex<[Repository.Changes]>([])
        let temp = FileManager.default.temporaryDirectory.appending(path: "plume-tree-\(UUID().uuidString)")
        let watched = Repository(
            client: repository.client, store: try MetadataStore(url: temp.appending(path: "store.sqlite")),
            files: LocalFiles(container: temp, caches: temp.appending(path: "Caches")),
            onChange: { changes in collected.withLock { $0.append(changes) } })
        try await inBase {
            let a = try await watched.createFolder(named: "A", in: base)
            let b = try await watched.createFolder(named: "B", in: a.path)
            let file = try temporaryFile("deep.txt", bytes: 5)
            try await watched.client.upload(file, to: b.path.appending("Été.txt"), overwrite: false)

            #expect(try await watched.syncTree(from: base) == 3)
            #expect(watched.store.search("ete").map(\.path) == [b.path.appending("Été.txt")])
            #expect(collected.withLock { $0 }.flatMap(\.updated).contains { $0.name == "Été.txt" })

            // Nothing changed: only the starting folder is listed again.
            #expect(try await watched.syncTree(from: base) == 1)

            try await watched.client.delete(b.path)
            collected.withLock { $0 = [] }
            try await watched.syncTree(from: base)
            #expect(Set(collected.withLock { $0 }.flatMap(\.removed).map(\.name)) == ["B", "Été.txt"])
        }
    }

    @Test func versionsRestoreAndTrash() async throws {
        try await inBase {
            let client = repository.client
            let path = base.appending("notes.txt")
            for text in ["one", "two", "three"] {
                let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try Data(text.utf8).write(to: file)
                try await client.upload(file, to: path, overwrite: true)
                // Versions are named by second.
                try await Task.sleep(for: .milliseconds(1100))
            }
            let item = try await client.item(at: path)
            let versions = try await client.versions(of: item)
            #expect(versions.count >= 2)
            // The oldest version holds "one": restore it.
            let oldest = try #require(versions.last)
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try await client.download(oldest, to: copy)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "one")
            try await client.restore(oldest)
            let restored = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try await client.download(path, to: restored)
            #expect(try String(contentsOf: restored, encoding: .utf8) == "one")

            // Delete, find it in the trash, put it back.
            try await client.delete(path)
            let trashed = try #require(try await client.trash().first { $0.originalLocation == path })
            #expect(trashed.name == "notes.txt")
            #expect(!trashed.isDirectory)
            try await client.restore(trashed)
            #expect(try await client.item(at: path).name == "notes.txt")
            #expect(try await client.trash().contains { $0.id == trashed.id } == false)

            // Delete again, then for good.
            try await client.delete(path)
            let again = try #require(try await client.trash().first { $0.originalLocation == path })
            try await client.deletePermanently(again)
            #expect(try await client.trash().contains { $0.id == again.id } == false)
        }
    }

    @Test func sharingLinksAndUsers() async throws {
        try await inBase {
            let client = repository.client
            let folder = base.appending("Shared")
            _ = try await client.createFolder(at: folder)
            let capabilities = try await client.capabilities()
            #expect(capabilities.linksEnabled)

            let expiry = Calendar.current.date(byAdding: .day, value: 10, to: .now)!
            var link = try await client.createLink(for: folder, password: "Plume-Test-Pass-9876", expiration: expiry)
            #expect(link.kind == .link)
            #expect(link.hasPassword)
            #expect(link.url != nil)
            #expect(link.expiration != nil)
            link = try await client.update(link, permissions: Permission.edit(isDirectory: true),
                                           password: "", expiration: .some(nil))
            #expect(link.canEdit)
            #expect(!link.hasPassword)
            #expect(link.expiration == nil)

            // A weak password is refused with the server's explanation.
            await #expect(throws: PlumeError.self) {
                _ = try await client.update(link, password: "1")
            }

            let others = try await client.sharees(matching: "", isDirectory: true)
            if let someone = others.first(where: { !$0.isGroup && $0.shareWith != client.account.userID }) {
                let share = try await client.share(folder, with: someone, permissions: Permission.read)
                #expect(share.kind == .user)
                #expect(!share.canEdit)
                try await client.delete(share)
            }
            #expect(try await client.shares(of: folder).map(\.id) == [link.id])
            try await client.delete(link)
            #expect(try await client.shares(of: folder).isEmpty)
        }
    }
}
