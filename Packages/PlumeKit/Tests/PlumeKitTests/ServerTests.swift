import Foundation
@testable import PlumeKit
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
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: bytes, by: 4096) { buffer[index] = UInt8(index / 4096 % 251) }
        }
        try data.write(to: url)
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
}
