import Foundation

/// Reads a WebDAV multistatus (PROPFIND, SEARCH, REPORT) into items. Only the
/// properties of a `200` propstat count; hrefs are turned into paths relative
/// to the user's files folder, and responses outside it are dropped.
final class DAVParser: NSObject, XMLParserDelegate {
    /// Decoded path of the user's files folder, e.g. `/remote.php/dav/files/alice`.
    private let filesRoot: String

    private var items: [RemoteItem] = []
    private var text = ""
    private var href: String?
    private var props: [String: String] = [:]
    private var propstatProps: [String: String] = [:]
    private var propstatIsCollection = false
    private var isCollection = false
    private var status: String?
    private var inPropstat = false
    private var inResourceType = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    init(filesRoot: String) {
        var root = filesRoot.removingPercentEncoding ?? filesRoot
        while root.hasSuffix("/") { root.removeLast() }
        self.filesRoot = root
    }

    static func parse(_ data: Data, filesRoot: String) throws -> [RemoteItem] {
        let delegate = DAVParser(filesRoot: filesRoot)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw PlumeError.invalidResponse(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            href = nil
            props = [:]
            isCollection = false
        case "propstat":
            inPropstat = true
            propstatProps = [:]
            propstatIsCollection = false
            status = nil
        case "resourcetype":
            inResourceType = true
        case "collection" where inResourceType:
            propstatIsCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href" where !inPropstat:
            href = value
        case "status" where inPropstat:
            status = value
        case "resourcetype":
            inResourceType = false
        case "propstat":
            inPropstat = false
            if status?.contains(" 200") ?? false {
                props.merge(propstatProps) { _, new in new }
                isCollection = isCollection || propstatIsCollection
            }
        case "response":
            if let item = makeItem() { items.append(item) }
        default:
            if inPropstat && !inResourceType { propstatProps[elementName] = value }
        }
        text = ""
    }

    private func makeItem() -> RemoteItem? {
        guard let href else { return nil }
        // The href is a percent-encoded absolute path (some servers send a
        // full URL).
        var path = href
        if let url = URL(string: href), url.scheme != nil { path = url.path(percentEncoded: true) }
        path = path.removingPercentEncoding ?? path
        guard path == filesRoot || path.hasPrefix(filesRoot + "/") else { return nil }
        let relative = RemotePath(String(path.dropFirst(filesRoot.count)))

        let size: Int64
        if isCollection {
            size = Int64(props["size"] ?? "") ?? 0
        } else {
            size = Int64(props["getcontentlength"] ?? "") ?? Int64(props["size"] ?? "") ?? 0
        }
        return RemoteItem(
            path: relative,
            fileID: props["fileid"] ?? "",
            isDirectory: isCollection,
            size: size,
            modified: props["getlastmodified"].flatMap { dateFormatter.date(from: $0) },
            etag: (props["getetag"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            contentType: props["getcontenttype"].flatMap { $0.isEmpty ? nil : $0 },
            permissions: props["permissions"] ?? "",
            isFavorite: props["favorite"] == "1",
            hasPreview: props["has-preview"] == "true"
        )
    }
}
