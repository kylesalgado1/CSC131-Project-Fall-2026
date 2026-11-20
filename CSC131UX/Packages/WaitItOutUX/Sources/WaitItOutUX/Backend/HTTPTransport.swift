import Foundation

/// The one way the package talks to the network. The host injects `URLSessionTransport`;
/// tests inject a scripted transport, so no test ever opens a connection.
///
/// Implementations return the body and the HTTP response for every status, including errors,
/// and throw only when no HTTP answer arrived (a `URLError`, or `CancellationError`).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
