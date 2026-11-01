import Foundation
@testable import PlumeKit
import Testing

@Suite struct RemotePathTests {
    @Test func normalizes() {
        #expect(RemotePath("/a//b/").rawValue == "a/b")
        #expect(RemotePath("").isRoot)
        #expect(RemotePath("a/b/c.pdf").parent == RemotePath("a/b"))
        #expect(RemotePath("a").parent == .root)
        #expect(RemotePath.root.parent == nil)
        #expect(RemotePath.root.appending("x") == RemotePath("x"))
    }

    @Test func containment() {
        #expect(RemotePath("a").contains(RemotePath("a/b")))
        #expect(!RemotePath("a").contains(RemotePath("ab")))
        #expect(RemotePath.root.contains(RemotePath("anything")))
    }

    @Test func serverURLs() {
        #expect(LoginFlow.normalizedServerURL("cloud.example.com")?.absoluteString == "https://cloud.example.com")
        #expect(LoginFlow.normalizedServerURL("https://example.com/nextcloud/index.php/login?x=1")?.absoluteString
                == "https://example.com/nextcloud")
        #expect(LoginFlow.normalizedServerURL("  ") == nil)
    }

    @Test func encodesPaths() {
        let client = NextcloudClient(credentials: Credentials(
            account: Account(server: URL(string: "https://example.com/nc")!, loginName: "a", userID: "alice"),
            appPassword: "x"))
        #expect(client.url(for: RemotePath("My Docs/a#b?.pdf")).absoluteString
                == "https://example.com/nc/remote.php/dav/files/alice/My%20Docs/a%23b%3F.pdf")
    }
}

@Suite struct DAVParserTests {
    static let sample = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
          <d:response>
            <d:href>/nc/remote.php/dav/files/alice/Docs/</d:href>
            <d:propstat><d:prop>
              <d:getlastmodified>Tue, 07 Oct 2025 10:00:00 GMT</d:getlastmodified>
              <d:getetag>"abc"</d:getetag><d:resourcetype><d:collection/></d:resourcetype>
              <oc:fileid>10</oc:fileid><oc:size>2048</oc:size><oc:permissions>RGDNVCK</oc:permissions>
              <oc:favorite>0</oc:favorite>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            <d:propstat><d:prop><d:getcontentlength/><d:getcontenttype/></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
          </d:response>
          <d:response>
            <d:href>/nc/remote.php/dav/files/alice/Docs/R%C3%A9sum%C3%A9%201.pdf</d:href>
            <d:propstat><d:prop>
              <d:getetag>"def"</d:getetag><d:resourcetype/><d:getcontentlength>1024</d:getcontentlength>
              <d:getcontenttype>application/pdf</d:getcontenttype>
              <oc:fileid>11</oc:fileid><oc:permissions>RGDNVW</oc:permissions><oc:favorite>1</oc:favorite>
              <nc:has-preview>true</nc:has-preview>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
          <d:response><d:href>/nc/remote.php/dav/files/bob/</d:href></d:response>
        </d:multistatus>
        """

    @Test func parsesFolderAndFile() throws {
        let items = try DAVParser.parse(Data(Self.sample.utf8), filesRoot: "/nc/remote.php/dav/files/alice")
        #expect(items.count == 2)
        let folder = items[0]
        #expect(folder.path == RemotePath("Docs"))
        #expect(folder.isDirectory)
        #expect(folder.size == 2048)
        #expect(folder.etag == "abc")
        #expect(folder.modified == Date(timeIntervalSince1970: 1_759_831_200))
        let file = items[1]
        #expect(file.path == RemotePath("Docs/Résumé 1.pdf"))
        #expect(!file.isDirectory)
        #expect(file.size == 1024)
        #expect(file.isFavorite)
        #expect(file.hasPreview)
        #expect(file.fileID == "11")
        #expect(file.utType == .pdf)
    }
}

@Suite struct MetadataStoreTests {
    func makeStore() throws -> MetadataStore {
        try MetadataStore(url: FileManager.default.temporaryDirectory
            .appending(path: "plume-tests-\(UUID().uuidString)/store.sqlite"))
    }

    func folder(_ path: String, etag: String = "1") -> RemoteItem {
        RemoteItem(path: RemotePath(path), fileID: "id-" + path, isDirectory: true, etag: etag)
    }

    func file(_ path: String, etag: String = "1") -> RemoteItem {
        RemoteItem(path: RemotePath(path), fileID: "id-" + path, isDirectory: false, size: 3, etag: etag)
    }

    @Test func replacingChildrenReportsRemovedSubtrees() throws {
        let store = try makeStore()
        store.replaceChildren(of: folder("", etag: "r1"), with: [folder("A"), file("b.txt")])
        store.replaceChildren(of: folder("A"), with: [file("A/x.pdf"), folder("A/Sub")])
        #expect(store.children(of: .root).map(\.name) == ["A", "b.txt"])
        #expect(store.listedEtag(of: RemotePath("A")) == "1")
        #expect(store.item(fileID: "id-A/x.pdf")?.path == RemotePath("A/x.pdf"))

        let removed = store.replaceChildren(of: folder("", etag: "r2"), with: [file("b.txt", etag: "2")])
        #expect(Set(removed.map(\.path.rawValue)) == ["A", "A/x.pdf", "A/Sub"])
        #expect(store.item(at: RemotePath("A/x.pdf")) == nil)
        #expect(store.item(at: RemotePath("b.txt"))?.etag == "2")
        #expect(store.listedEtag(of: .root) == "r2")
    }

    @Test func folderKeepsListingEtagUntilRelisted() throws {
        let store = try makeStore()
        store.replaceChildren(of: folder("", etag: "r1"), with: [folder("A", etag: "a1")])
        store.replaceChildren(of: folder("A", etag: "a1"), with: [])
        store.replaceChildren(of: folder("", etag: "r2"), with: [folder("A", etag: "a2")])
        #expect(store.item(at: RemotePath("A"))?.etag == "a2")
        #expect(store.listedEtag(of: RemotePath("A")) == "a1")
    }

    @Test func searchAndPins() throws {
        let store = try makeStore()
        store.replaceChildren(of: folder(""), with: [folder("Taxes"), file("100%_real.txt")])
        store.replaceChildren(of: folder("Taxes"), with: [file("Taxes/Return 2025.pdf")])
        #expect(store.search("return").map(\.name) == ["Return 2025.pdf"])
        #expect(store.search("taxes").map(\.name) == ["Taxes"])
        #expect(store.search("%_").map(\.name) == ["100%_real.txt"])
        store.upsert(file("Taxes/Résumé Final.pdf"))
        #expect(store.search("resume").map(\.name) == ["Résumé Final.pdf"])
        #expect(store.search("RÉSU").map(\.name) == ["Résumé Final.pdf"])
        // Names starting with the term come first.
        store.upsert(file("Taxes/Old return.pdf"))
        #expect(Set(store.search("re").prefix(2).map(\.name)) == ["Résumé Final.pdf", "Return 2025.pdf"])
        store.pin(RemotePath("Taxes"))
        #expect(store.isPinned(RemotePath("Taxes/Return 2025.pdf")))
        #expect(!store.isPinned(RemotePath("100%_real.txt")))
    }
}

struct ErrorTests {
    @Test func networkErrorsAreExplained() {
        #expect(PlumeError.from(URLError(.serverCertificateUntrusted)) as? PlumeError == .untrustedCertificate)
        #expect(PlumeError.from(URLError(.serverCertificateHasBadDate)) as? PlumeError == .untrustedCertificate)
        #expect(PlumeError.from(URLError(.timedOut)) as? PlumeError == .offline)
        #expect(PlumeError.from(URLError(.notConnectedToInternet)) as? PlumeError == .offline)
        #expect(PlumeError.from(URLError(.cancelled)) is CancellationError)
    }

    @Test func statusCodesAreExplained() throws {
        let client = NextcloudClient(credentials: Credentials(
            account: Account(server: URL(string: "https://cloud.example.com")!, loginName: "a", userID: "a"),
            appPassword: "x"))
        func response(_ status: Int, _ headers: [String: String] = [:]) -> URLResponse {
            HTTPURLResponse(url: URL(string: "https://cloud.example.com")!, statusCode: status,
                            httpVersion: nil, headerFields: headers)!
        }
        #expect(throws: PlumeError.forbidden) { try client.check(response(403), data: nil) }
        #expect(throws: PlumeError.maintenance) {
            try client.check(response(503, ["X-Nextcloud-Maintenance-Mode": "1"]), data: nil)
        }
        #expect(throws: PlumeError.http(503)) { try client.check(response(503), data: nil) }
        #expect(throws: PlumeError.insufficientStorage) { try client.check(response(507), data: nil) }
        #expect(throws: PlumeError.unauthorized) { try client.check(response(401), data: nil) }
    }

    @Test func notNextcloudIsExplained() async {
        await #expect(throws: PlumeError.self) {
            _ = try await LoginFlow.start(server: URL(string: "https://example.com")!)
        }
    }
}

@Suite struct WebDAVIdentityTests {
    func makeStore() throws -> MetadataStore {
        try MetadataStore(url: FileManager.default.temporaryDirectory
            .appending(path: "plume-tests-\(UUID().uuidString)/store.sqlite"))
    }

    func item(_ path: String, directory: Bool = false) -> RemoteItem {
        RemoteItem(path: RemotePath(path), fileID: "", isDirectory: directory, etag: "")
    }

    @Test func itemsWithoutIDsGetStableOnes() throws {
        let store = try makeStore()
        let first = store.upsert(item("Docs/a.pdf"))
        #expect(first.fileID.hasPrefix("w"))
        #expect(store.upsert(item("Docs/a.pdf")).fileID == first.fileID)
        #expect(store.identified([item("Docs/a.pdf")]).first?.fileID == first.fileID)
        #expect(store.upsert(item("Docs/b.pdf")).fileID != first.fileID)
        #expect(store.item(fileID: first.fileID)?.path == RemotePath("Docs/a.pdf"))
    }

    @Test func listingsGetIDsToo() throws {
        let store = try makeStore()
        store.replaceChildren(of: item("", directory: true), with: [item("Docs", directory: true), item("x.txt")])
        #expect(store.children(of: .root).allSatisfy { !$0.fileID.isEmpty })
    }

    @Test func movesKeepIDsForTheWholeSubtree() throws {
        let store = try makeStore()
        let folder = store.upsert(item("Docs", directory: true))
        let file = store.upsert(item("Docs/Sub/a.pdf"))
        store.upsert(item("Docs/Sub", directory: true))
        store.move(RemotePath("Docs"), to: RemotePath("Archive/Docs 2024"))
        #expect(store.item(at: RemotePath("Archive/Docs 2024"))?.fileID == folder.fileID)
        #expect(store.item(at: RemotePath("Archive/Docs 2024/Sub/a.pdf"))?.fileID == file.fileID)
        #expect(store.item(at: RemotePath("Archive/Docs 2024/Sub/a.pdf"))?.path.parent == RemotePath("Archive/Docs 2024/Sub"))
        #expect(store.children(of: RemotePath("Archive/Docs 2024/Sub")).map(\.fileID) == [file.fileID])
        #expect(store.item(at: RemotePath("Docs")) == nil)
        #expect(store.search("docs 2024").map(\.fileID) == [folder.fileID])
        #expect(store.upsert(item("Archive/Docs 2024/Sub/a.pdf")).fileID == file.fileID)
    }

    @Test func aNewItemAtAMovedPathGetsANewID() throws {
        let store = try makeStore()
        let moved = store.upsert(item("a.txt"))
        store.move(RemotePath("a.txt"), to: RemotePath("b.txt"))
        let fresh = store.upsert(item("a.txt"))
        #expect(fresh.fileID != moved.fileID)
        #expect(store.item(fileID: moved.fileID)?.path == RemotePath("b.txt"))
        #expect(store.item(fileID: fresh.fileID)?.path == RemotePath("a.txt"))
    }

    @Test func savedAccountsStayNextcloud() throws {
        let saved = Data(#"{"server":"https://cloud.example.com","loginName":"a","userID":"a"}"#.utf8)
        let account = try JSONDecoder().decode(Account.self, from: saved)
        #expect(account.kind == .nextcloud)
        let webdav = Account(server: URL(string: "https://nas.example.com/dav")!, loginName: "a", userID: "a", kind: .webdav)
        #expect(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(webdav)).kind == .webdav)
    }

    @Test func webDAVAddresses() {
        #expect(LoginFlow.webDAVURL("nas.example.com/dav/")?.absoluteString == "https://nas.example.com/dav")
        #expect(LoginFlow.webDAVURL("http://192.168.1.2:8080/remote.php/webdav")?.absoluteString
                == "http://192.168.1.2:8080/remote.php/webdav")
        #expect(LoginFlow.webDAVURL("ftp://example.com") == nil)
        #expect(LoginFlow.webDAVURL(" ") == nil)
    }

    @Test func webDAVClientUsesTheAddressAsRoot() {
        let client = NextcloudClient(credentials: Credentials(
            account: Account(server: URL(string: "https://nas.example.com/dav")!, loginName: "a", userID: "a", kind: .webdav),
            appPassword: "p"))
        #expect(client.url(for: RemotePath("My Files/é.txt")).absoluteString
                == "https://nas.example.com/dav/My%20Files/%C3%A9.txt")
        #expect(ServerCapabilities(account: client.account).favorites == false)
    }
}
