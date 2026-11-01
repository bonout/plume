import Foundation
@testable import PlumeKit
import Testing

enum TestWebDAV {
    static var settings: (url: URL, user: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["PLUME_TEST_WEBDAV"].flatMap(URL.init(string:)),
              let user = env["PLUME_TEST_WEBDAV_USER"], let password = env["PLUME_TEST_WEBDAV_PASSWORD"] else { return nil }
        return (url, user, password)
    }
}

@Suite(.enabled(if: TestWebDAV.settings != nil, "PLUME_TEST_WEBDAV is not set"), .serialized)
struct WebDAVTests {
    let repository: Repository
    let base: RemotePath

    init() async throws {
        let settings = TestWebDAV.settings!
        let credentials = try await LoginFlow.signInWebDAV(server: settings.url, user: settings.user,
                                                            password: settings.password)
        let temp = FileManager.default.temporaryDirectory.appending(path: "plume-webdav-\(UUID().uuidString)")
        repository = Repository(
            client: NextcloudClient(credentials: credentials),
            store: try MetadataStore(url: temp.appending(path: "store.sqlite")),
            files: LocalFiles(container: temp, caches: temp.appending(path: "Caches")))
        base = RemotePath("Plume WebDAV \(UUID().uuidString.prefix(8))")
        _ = try await repository.client.createFolder(at: base)
    }

    func inBase(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            try? await repository.client.delete(base)
            throw error
        }
        try await repository.client.delete(base)
    }

    func localFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func refusesWrongPasswordsAndNonDAVAddresses() async throws {
        let settings = TestWebDAV.settings!
        await #expect(throws: PlumeError.unauthorized) {
            _ = try await LoginFlow.signInWebDAV(server: settings.url, user: settings.user, password: "wrong")
        }
        await #expect(throws: PlumeError.notWebDAV) {
            _ = try await LoginFlow.signInWebDAV(server: settings.url.appending(path: "missing-\(UUID().uuidString)"),
                                                 user: settings.user, password: settings.password)
        }
        try await repository.client.delete(base)
    }

    @Test func browsesUploadsAndDownloads() async throws {
        try await inBase {
            let folder = try await repository.createFolder(named: "Docs", in: base)
            #expect(!folder.fileID.isEmpty)
            let uploaded = try await repository.upload(try localFile("hello"), named: "a.txt", into: folder.path)
            let again = try await repository.upload(try localFile("other"), named: "a.txt", into: folder.path)
            #expect(again.name == "a 2.txt")
            let listing = try await repository.refresh(folder.path)
            #expect(listing.children.map(\.name) == ["a 2.txt", "a.txt"])
            #expect(listing.children.allSatisfy { !$0.fileID.isEmpty && $0.canWrite && $0.canDelete && $0.canRename })
            #expect(listing.children.first { $0.name == "a.txt" }?.fileID == uploaded.fileID)
            let copy = try await repository.localCopy(of: uploaded)
            #expect(try String(contentsOf: copy, encoding: .utf8) == "hello")
        }
    }

    @Test func renamesKeepIDs() async throws {
        try await inBase {
            let folder = try await repository.createFolder(named: "Old", in: base)
            let file = try await repository.upload(try localFile("x"), named: "x.txt", into: folder.path)
            try await repository.refresh(folder.path)
            let renamed = try await repository.rename(folder, to: "New")
            #expect(renamed.fileID == folder.fileID)
            let listing = try await repository.refresh(renamed.path)
            #expect(listing.children.first?.fileID == file.fileID)
            #expect(repository.store.item(fileID: file.fileID)?.path == renamed.path.appending("x.txt"))
            let other = try await repository.createFolder(named: "Other", in: base)
            await #expect(throws: PlumeError.alreadyExists) { _ = try await repository.rename(other, to: "New") }
        }
    }

    @Test func changesDeepInTheTreeAreFound() async throws {
        try await inBase {
            let top = try await repository.createFolder(named: "Top", in: base)
            let deep = try await repository.createFolder(named: "Deep", in: top.path)
            try await repository.syncTree(from: base)
            _ = try await repository.client.upload(try localFile("new"), to: deep.path.appending("new.txt"), overwrite: false)
            let changes = try await repository.changes(under: base)
            #expect(changes.updated.contains { $0.path == deep.path.appending("new.txt") })
            try await repository.client.delete(deep.path.appending("new.txt"))
            let after = try await repository.changes(under: base)
            #expect(after.removed.contains { $0.path == deep.path.appending("new.txt") })
        }
    }

    @Test func quotaAndNextcloudOnlyCalls() async throws {
        _ = try await repository.client.userInfo()
        #expect(try await repository.client.favorites().isEmpty)
        #expect(try await repository.client.search("a").isEmpty)
        await #expect(throws: PlumeError.unsupported) { _ = try await repository.client.publicLink(for: base) }
        try await repository.client.revokeAppPassword()
        try await repository.client.delete(base)
    }

    @Test func largeFilesGoInOneRequest() async throws {
        try await inBase {
            let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data(repeating: 7, count: 40 * 1024 * 1024).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let item = try await repository.upload(url, named: "big.bin", into: base)
            #expect(item.size == 40 * 1024 * 1024)
        }
    }
}
