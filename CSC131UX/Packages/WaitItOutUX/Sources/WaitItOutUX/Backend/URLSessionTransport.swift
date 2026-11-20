import Foundation

/// The production `HTTPTransport`. This is the only file in the app that names the system
/// networking session; `scripts/check_project_structure.py` allows it here and nowhere else.
///
/// The session is ephemeral: no cookies, no cache, and nothing written to disk. A request
/// gives up after 25 seconds without progress and a whole exchange after 60 seconds, so a
/// sleeping server becomes a visible "did not answer in time" instead of an endless spinner.
/// It does not wait for connectivity: being offline fails at once and the model retries.
public struct URLSessionTransport: HTTPTransport {
    /// Seconds a request may sit idle before it times out.
    public static let requestTimeout: TimeInterval = 25
    /// Seconds a whole exchange may take.
    public static let resourceTimeout: TimeInterval = 60

    private let session: URLSession

    public init() {
        session = URLSession(configuration: Self.makeConfiguration())
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// The session settings described above.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
