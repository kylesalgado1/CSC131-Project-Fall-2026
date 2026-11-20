import Foundation

/// One HTTP answer from the backend, whatever its status.
struct BackendReply: Sendable {
    let status: Int
    let data: Data
    /// The body's `error` code for a non-2xx answer with a JSON error body, else `nil`.
    let errorCode: String?
    /// The body's human sentence for a non-2xx answer with a JSON error body, else `nil`.
    let errorMessage: String?

    var isSuccess: Bool {
        (200..<300).contains(status)
    }
}

/// What POST /verdict answered.
enum VerdictAnswer: Sendable {
    case verdict(WireVerdictResponse)
    /// HTTP 422 `no_coverage`: the backend has no traffic data for this route. The message is
    /// the backend's own sentence when it sent one.
    case noCoverage(message: String?)
}

/// The team backend's HTTP API (SPEC-API). Stateless: every call reads the current address
/// from `BackendConfiguration`, so a changed address applies to the next request. Failures
/// surface as `CommuteProviderFailure`; a cancelled request throws `CancellationError`.
/// Bodies, coordinates, and credentials are never logged.
public struct BackendClient: Sendable {
    /// Seconds one request may sit idle before it counts as timed out.
    public static let requestTimeout: TimeInterval = 25

    let configuration: BackendConfiguration
    let transport: any HTTPTransport
    let clock: any WallClock

    public init(configuration: BackendConfiguration, transport: any HTTPTransport, clock: any WallClock) {
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
    }

    // MARK: Endpoints

    /// POST /verdict for one trip. No preferences are sent.
    func verdict(origin: GeoCoordinate, destination: GeoCoordinate, arriveBy: Date) async throws -> VerdictAnswer {
        let body = try encode(WireVerdictRequest(origin: WirePoint(origin), destination: WirePoint(destination), arriveBy: arriveBy))
        let reply = try await send(method: "POST", path: ["verdict"], body: body)
        if reply.isSuccess {
            return .verdict(try decode(WireVerdictResponse.self, from: reply))
        }
        // Discriminated by the body's code first; a bare 422 means the same thing.
        if reply.errorCode == "no_coverage" || (reply.status == 422 && reply.errorCode == nil) {
            return .noCoverage(message: reply.errorMessage)
        }
        throw failure(for: reply)
    }

    /// POST /route for the driving geometry between two points. Throws
    /// `RouteProviderFailure.notSupported` when the server has no such endpoint (a 404 that is
    /// not the API's own `not_found`) or no path provider (`route_unavailable`).
    func route(origin: GeoCoordinate, destination: GeoCoordinate) async throws -> WireRouteResponse {
        let body = try encode(WireRouteRequest(origin: WirePoint(origin), destination: WirePoint(destination)))
        let reply = try await send(method: "POST", path: ["route"], body: body)
        if reply.isSuccess {
            return try decode(WireRouteResponse.self, from: reply)
        }
        if reply.errorCode == "route_unavailable" || (reply.status == 404 && reply.errorCode != "not_found") {
            throw RouteProviderFailure.notSupported
        }
        throw failure(for: reply)
    }

    // MARK: Request helper

    /// Sends one request and returns the answer for any HTTP status. `path` is a list of
    /// segments, each percent-encoded as one segment. `baseURL` pins the server for this one
    /// request, so a credential is never sent to an address that changed meanwhile; without
    /// it the address in use now applies. Throws `.notConfigured` without a base address,
    /// `CancellationError` when cancelled, and a `CommuteProviderFailure` for every transport
    /// error.
    func send(
        method: String,
        path: [String],
        body: Data? = nil,
        bearerToken: String? = nil,
        baseURL: URL? = nil
    ) async throws -> BackendReply {
        try Task.checkCancellation()
        guard let url = Self.url(base: baseURL ?? configuration.baseURL, path: path) else {
            throw CommuteProviderFailure(.notConfigured)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw CommuteProviderFailure(Self.kind(for: error.code))
        } catch let failure as CommuteProviderFailure {
            throw failure
        } catch {
            // A transport that fails without a URL error did not reach the backend.
            throw CommuteProviderFailure(.offline)
        }
        let status = response.statusCode
        guard !(200..<300).contains(status) else {
            return BackendReply(status: status, data: data, errorCode: nil, errorMessage: nil)
        }
        let errorBody = try? BackendJSON.makeDecoder().decode(WireErrorBody.self, from: data)
        return BackendReply(
            status: status,
            data: data,
            errorCode: errorBody?.error,
            errorMessage: Self.sentence(errorBody?.message)
        )
    }

    /// The failure for an error answer no caller handles itself, discriminated by the body's
    /// code first: `routing_unavailable`, then `temporarily_unavailable` (the server's "try
    /// again shortly", always a transient server failure), then `unauthorized` (or a bare 401),
    /// else the status. A gateway's 502 or 503 without a JSON body is therefore
    /// `.server(status:)`.
    func failure(for reply: BackendReply) -> CommuteProviderFailure {
        if reply.errorCode == "routing_unavailable" { return CommuteProviderFailure(.routingUnavailable) }
        if reply.errorCode == "temporarily_unavailable" {
            return CommuteProviderFailure(.server(status: reply.status >= 500 ? reply.status : 503))
        }
        if reply.errorCode == "unauthorized" || reply.status == 401 { return CommuteProviderFailure(.unauthorized) }
        return CommuteProviderFailure(.server(status: reply.status))
    }

    func decode<Value: Decodable>(_ type: Value.Type, from reply: BackendReply) throws -> Value {
        do {
            return try BackendJSON.makeDecoder().decode(type, from: reply.data)
        } catch {
            throw CommuteProviderFailure(.invalidResponse)
        }
    }

    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try BackendJSON.makeEncoder().encode(value)
        } catch {
            // Only a nonfinite number cannot be written; such a request is never sent.
            throw CommuteProviderFailure(.invalidResponse)
        }
    }

    // MARK: Pure helpers

    /// `base` with `path` appended, each segment percent-encoded as a single segment so an id
    /// can never add or remove a path level. `nil` without a base.
    static func url(base: URL?, path: [String]) -> URL? {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let segments = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        guard !segments.contains(where: \.isEmpty) else { return nil }
        let prefix = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = prefix + "/" + segments.joined(separator: "/")
        return components.url
    }

    /// Every transport error maps to a defined kind: a timeout, an unreadable or untrusted
    /// answer (bad response, TLS, App Transport Security), or else a connection that could not
    /// be made.
    static func kind(for code: URLError.Code) -> CommuteProviderFailure.Kind {
        switch code {
        case .timedOut:
            return .timedOut
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData,
             .zeroByteResource, .dataLengthExceedsMaximum, .httpTooManyRedirects, .redirectToNonExistentLocation,
             .badURL, .unsupportedURL, .userAuthenticationRequired, .userCancelledAuthentication,
             .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .invalidResponse
        default:
            // Connection-class errors: no internet, a lost or refused connection, DNS, roaming
            // or data restrictions, and anything else that kept the request from arriving.
            return .offline
        }
    }

    /// A trimmed, nonempty, bounded sentence from an error body, or `nil`.
    static func sentence(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(300))
    }
}
