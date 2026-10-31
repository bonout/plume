import Foundation

extension NextcloudClient {
    /// Yields each time a file changes on the server, through notify_push's
    /// websocket (the "Client Push" app). Ends with an error when the
    /// connection drops: the caller reconnects.
    ///
    /// The protocol: the client sends the login name, then the app
    /// password; the server answers `authenticated`, then sends
    /// `notify_file` whenever one of the user's files changes.
    public func fileChanges(at socket: URL) -> AsyncThrowingStream<Void, Error> {
        AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: socket)
            let credentials = credentials
            let reader = Task {
                do {
                    task.resume()
                    try await task.send(.string(credentials.account.loginName))
                    try await task.send(.string(credentials.appPassword))
                    while !Task.isCancelled {
                        let text: String
                        switch try await task.receive() {
                        case .string(let string): text = string
                        case .data(let data): text = String(decoding: data, as: UTF8.self)
                        @unknown default: continue
                        }
                        if text.hasPrefix("err") {
                            throw text.contains("auth") ? PlumeError.unauthorized : PlumeError.refused(text)
                        }
                        if text.hasPrefix("notify_file") { continuation.yield() }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
