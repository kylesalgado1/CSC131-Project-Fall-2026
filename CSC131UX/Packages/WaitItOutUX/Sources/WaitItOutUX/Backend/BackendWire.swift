import Foundation

/// The wire contract between the app and the team backend: JSON bodies exactly as the backend
/// sends and expects them. Internal to the package; the providers map these to the app's own
/// types explicitly, so a wire spelling never leaks into the domain. Unknown fields are
/// ignored, and every field the backend may omit is optional here and checked by the mapper.

/// Dates on the wire: ISO-8601 with a zone designator, as JavaScript's `Date.toISOString()`
/// writes them ("2026-11-20T15:30:00.000Z"). Parsing accepts them with or without fractional
/// seconds; writing always uses milliseconds and "Z".
enum BackendDate {
    static func parse(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text)
    }

    static func string(from date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }
}

/// JSON coding for the wire: dates through `BackendDate`.
enum BackendJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = BackendDate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 date with a zone designator")
            }
            return date
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(BackendDate.string(from: date))
        }
        return encoder
    }
}

/// `{ lat, lng }`.
struct WirePoint: Codable, Equatable, Sendable {
    let lat: Double
    let lng: Double

    init(_ coordinate: GeoCoordinate) {
        lat = coordinate.latitude
        lng = coordinate.longitude
    }

    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: lat, longitude: lng)
    }
}

/// POST /verdict request. No preferences are sent: the server derives the arrive-by goal from
/// `arriveBy` and applies its own defaults.
struct WireVerdictRequest: Encodable, Sendable {
    let origin: WirePoint
    let destination: WirePoint
    let arriveBy: Date
}

/// One departure of a verdict: leave at `departAt`, arrive at `arriveAt`.
struct WireDeparture: Decodable, Sendable {
    let departAt: Date
    let arriveAt: Date
    let driveMinutes: Double?
}

struct WireDeadline: Decodable, Sendable {
    let marginMinutes: Double?
}

/// The verdict of POST /verdict. `action` and `confidence` stay strings here and are mapped
/// explicitly by `BackendCommuteProvider`.
struct WireVerdict: Decodable, Sendable {
    let action: String
    let reason: String?
    let leaveNow: WireDeparture?
    let recommended: WireDeparture?
    let lateByMinutes: Double?
    let deadline: WireDeadline?
    let confidence: String?
    let confidenceReason: String?
    let notes: [String]?
    let generatedAt: Date?
}

/// Where the backend's figures came from. Absent on servers that predate the field.
struct WireSource: Decodable, Sendable {
    let baseline: String?
    let fallback: Bool?
    let live: Bool?
}

/// POST /verdict response. `slots` is not read.
struct WireVerdictResponse: Decodable, Sendable {
    let verdict: WireVerdict
    let source: WireSource?
}

/// POST /route request.
struct WireRouteRequest: Encodable, Sendable {
    let origin: WirePoint
    let destination: WirePoint
}

/// POST /route response.
struct WireRouteResponse: Decodable, Sendable {
    struct Point: Decodable, Sendable {
        let lat: Double?
        let lng: Double?
    }

    let points: [Point]
    let distanceMiles: Double?
    let source: String?
    let fallback: Bool?
}

/// Every backend error: `{ "error": "snake_code", "message": "Human sentence." }`.
struct WireErrorBody: Decodable, Sendable {
    let error: String?
    let message: String?
}

// MARK: Devices and trips

/// POST /devices request.
struct WireRegisterRequest: Encodable, Sendable {
    let platform: String
}

/// The server's monitoring numbers. Every field is optional so an older server still decodes.
struct WireLimits: Decodable, Sendable {
    let planningHorizonMinutes: Double?
    let monitorLeadMinutes: Double?
    let headsUpLeadMinutes: Double?
    let meaningfulShiftMinutes: Double?
    let maxTrips: Int?
}

/// POST /devices response. The token is shown this once.
struct WireRegistration: Decodable, Sendable {
    let deviceId: String
    let token: String
    let limits: WireLimits?
}

/// PUT /devices/me/push request. `apnsToken` is always written, as `null` when there is none,
/// because the server requires the field.
struct WirePushRequest: Encodable, Sendable {
    let apnsToken: String?
    let environment: String
    let authorized: Bool

    private enum CodingKeys: String, CodingKey {
        case apnsToken
        case environment
        case authorized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let apnsToken {
            try container.encode(apnsToken, forKey: .apnsToken)
        } else {
            try container.encodeNil(forKey: .apnsToken)
        }
        try container.encode(environment, forKey: .environment)
        try container.encode(authorized, forKey: .authorized)
    }
}

/// Whether alerts can reach this device, as the server sees it.
struct WirePushStatus: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let reason: String?
    }

    let configured: Bool?
    let registered: Bool?
    let authorized: Bool?
    let lastFailure: Failure?
}

/// PUT /devices/me/push response.
struct WirePushResponse: Decodable, Sendable {
    let push: WirePushStatus
}

/// Whether anything checks trips while the app is closed.
struct WireMonitorHealth: Decodable, Sendable {
    let enabled: Bool?
    let dependable: Bool?
    let lastTickAt: Date?
}

/// One trip of a snapshot, as the app sends it: only the fields the server uses. The
/// contract's optional `destinationName` and `startsAt` are never sent, because the server
/// does nothing with them.
struct WireTripInput: Encodable, Equatable, Sendable {
    let id: String
    let title: String
    let origin: WirePoint
    let destination: WirePoint
    let arriveBy: Date
    let timeZone: String
}

/// PUT /trips request: the complete set of trips the device wants monitored.
struct WireSyncRequest: Encodable, Sendable {
    let revision: Int
    let trips: [WireTripInput]
}

/// The server's recommendation for a monitored trip. `action` and `confidence` stay strings
/// here and are mapped explicitly by `BackendSession`.
struct WireRecommendation: Decodable, Sendable {
    let action: String
    let departAt: Date
    let arriveAt: Date
    let driveMinutes: Double?
    let reason: String?
    let confidence: String?
    let confidenceReason: String?
    let notes: [String]?
    let lateByMinutes: Double?
    let marginMinutes: Double?
    let evaluatedAt: Date
    let source: WireSource?
    let stale: Bool?
}

/// The last alert queued for a trip, and what became of it.
struct WireLastAlert: Decodable, Sendable {
    let kind: String?
    let status: String?
    let at: Date?
    let reason: String?
}

/// The monitoring times of one trip.
struct WireTripMonitoring: Decodable, Sendable {
    let startsAt: Date?
    let startedAt: Date?
    let headsUpAt: Date?
    let headsUpSentAt: Date?
    let leaveAlertSentAt: Date?
    let endsAt: Date?
    let nextCheckAt: Date?
    let lastAlert: WireLastAlert?
}

struct WireTripError: Decodable, Sendable {
    let code: String?
    let at: Date?
}

/// Everything the server tells about one monitored trip. `phase` stays a string here.
struct WireTripState: Decodable, Sendable {
    let id: String
    let arriveBy: Date
    let phase: String
    let recommendation: WireRecommendation?
    let noPlanReason: String?
    let planAvailableAt: Date?
    let monitoring: WireTripMonitoring?
    let lastError: WireTripError?
}

/// The answer to PUT /trips and GET /trips.
struct WireSyncResponse: Decodable, Sendable {
    let revision: Int
    let applied: Bool?
    let serverTime: Date
    let limits: WireLimits?
    let push: WirePushStatus?
    let monitor: WireMonitorHealth?
    let trips: [WireTripState]
}

/// The answer to GET /trips/:id.
struct WireTripDetail: Decodable, Sendable {
    let trip: WireTripState
}

/// POST /trips/:id/departed request: which arrival time the user left for.
struct WireDepartedRequest: Encodable, Sendable {
    let arriveBy: Date
}

/// POST /trips/:id/departed response.
struct WireDepartedResponse: Decodable, Sendable {
    let trip: WireTripState
}

/// The extra field of a 409 `revision_conflict` body: the revision the server holds.
struct WireRevisionConflict: Decodable, Sendable {
    let revision: Int?
}
