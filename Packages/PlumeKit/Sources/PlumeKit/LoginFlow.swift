import Foundation

/// Nextcloud Login Flow v2: the user signs in in their browser (two-factor
/// included), and the server hands the app a dedicated app password, which
/// they can revoke from the server's security settings.
public struct LoginFlow: Sendable {
    /// The page to open in the browser.
    public let loginURL: URL
    private let pollURL: URL
    private let token: String

    /// Accepts `cloud.example.com`, `https://cloud.example.com/`, or a
    /// subdirectory install.
    public static func normalizedServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        components.query = nil
        components.fragment = nil
        var path = components.path
        for suffix in ["/index.php/login", "/index.php", "/login"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    public static func start(server: URL, userAgent: String = NextcloudClient.defaultUserAgent) async throws -> LoginFlow {
        var request = URLRequest(url: server.appending(path: "index.php/login/v2"))
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw PlumeError.from(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 503,
           http.value(forHTTPHeaderField: "X-Nextcloud-Maintenance-Mode") != nil {
            throw PlumeError.maintenance
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poll = json["poll"] as? [String: Any],
              let token = poll["token"] as? String,
              let endpoint = (poll["endpoint"] as? String).flatMap(URL.init(string:)),
              let login = (json["login"] as? String).flatMap(URL.init(string:))
        else {
            throw PlumeError.notNextcloud
        }
        return LoginFlow(loginURL: login, pollURL: endpoint, token: token)
    }

    /// Waits until the user has granted access in the browser (the server
    /// gives up after 20 minutes), then completes the account with its user
    /// id. Cancel the task to stop waiting.
    public func credentials() async throws -> Credentials {
        while true {
            try await Task.sleep(for: .seconds(2))
            var request = URLRequest(url: pollURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(token)".utf8)
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { continue }
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let server = json["server"].flatMap(URL.init(string:)),
                  let loginName = json["loginName"], let appPassword = json["appPassword"]
            else {
                throw PlumeError.invalidResponse("login flow")
            }
            return try await Self.complete(server: server, loginName: loginName, appPassword: appPassword)
        }
    }

    /// Checks an app password and looks up the user id (which the WebDAV
    /// path needs, and which isn't always the login name).
    public static func complete(server: URL, loginName: String, appPassword: String) async throws -> Credentials {
        let provisional = Credentials(
            account: Account(server: server, loginName: loginName, userID: loginName),
            appPassword: appPassword)
        let info = try await NextcloudClient(credentials: provisional).userInfo()
        return Credentials(
            account: Account(server: server, loginName: loginName, userID: info.id, displayName: info.displayName),
            appPassword: appPassword)
    }
}
