import Foundation
import Security

/// The signed-in Nextcloud account. Its app password lives in the keychain,
/// never here.
public struct Account: Codable, Sendable, Hashable, Identifiable {
    /// Base URL of the server, e.g. `https://cloud.example.com` (a
    /// subdirectory install keeps its path).
    public var server: URL
    /// Name used to authenticate (Basic auth).
    public var loginName: String
    /// Internal user id: the WebDAV folder is `remote.php/dav/files/<id>`.
    /// Often the login name, not always (LDAP, e-mail logins).
    public var userID: String
    public var displayName: String?

    public init(server: URL, loginName: String, userID: String, displayName: String? = nil) {
        self.server = server
        self.loginName = loginName
        self.userID = userID
        self.displayName = displayName
    }

    public var id: String { "\(userID)@\(server.host() ?? server.absoluteString)" }
    public var host: String { server.host() ?? server.absoluteString }
}

/// An account and its app password: what a client needs.
public struct Credentials: Sendable, Hashable {
    public var account: Account
    public var appPassword: String

    public init(account: Account, appPassword: String) {
        self.account = account
        self.appPassword = appPassword
    }
}

/// The app group shared by the app, its File Provider extension and its
/// share extension. Its identifier comes from the `PlumeAppGroup` key of the
/// running bundle's Info.plist (set by the build, see Config/Base.xcconfig).
public enum AppGroup {
    public static let identifier: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PlumeAppGroup") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }()

    /// The shared container; outside an app (unit tests), a temporary folder.
    public static let containerURL: URL = {
        if let identifier,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "PlumeGroup", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static var defaults: UserDefaults {
        identifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// `Library/Caches` inside the group container: the system may purge it.
    public static var cachesURL: URL {
        containerURL.appending(path: "Library/Caches", directoryHint: .isDirectory)
    }
}

/// Where the account is kept: its description in the group's defaults, its
/// app password in the keychain, in an access group equal to the app group
/// (so the extensions can read it, and nothing else).
public enum AccountStore {
    private static let accountKey = "account"
    private static let keychainService = "Plume app password"

    public static func load() -> Credentials? {
        guard let data = AppGroup.defaults.data(forKey: accountKey),
              let account = try? JSONDecoder().decode(Account.self, from: data),
              let password = Keychain.read(service: keychainService, account: account.id)
        else { return nil }
        return Credentials(account: account, appPassword: password)
    }

    public static func save(_ credentials: Credentials) throws {
        try Keychain.write(credentials.appPassword, service: keychainService, account: credentials.account.id)
        AppGroup.defaults.set(try JSONEncoder().encode(credentials.account), forKey: accountKey)
    }

    public static func remove() {
        if let data = AppGroup.defaults.data(forKey: accountKey),
           let account = try? JSONDecoder().decode(Account.self, from: data) {
            Keychain.delete(service: keychainService, account: account.id)
        }
        AppGroup.defaults.removeObject(forKey: accountKey)
    }
}

enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = AppGroup.identifier {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) throws {
        delete(service: service, account: account)
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = Data(value.utf8)
        // Readable by the File Provider extension while the device is locked
        // (background sync), after the first unlock since boot.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
