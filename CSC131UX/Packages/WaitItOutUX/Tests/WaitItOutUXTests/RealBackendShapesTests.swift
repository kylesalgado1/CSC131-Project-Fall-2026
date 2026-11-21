import XCTest
@testable import WaitItOutUX

/// The team backend's real answers, decoded through the app's production path.
///
/// Every body under `Captured` was captured from the real backend code (the fixture server's
/// routes and decision code over real HTTP), except `verdictProductionMain`, which is a real
/// answer of the team's currently deployed backend and therefore has no `source` field. Each
/// is embedded verbatim, byte for byte, and is never rebuilt by a helper, so a field renamed or
/// retyped on either side fails here. Nothing in this file opens a connection: the bodies are
/// served by the scripted transport, and read by `BackendClient`, `BackendCommuteProvider`,
/// `BackendRouteProvider`, `BackendSession`, and `TripNotificationPayload` exactly as in the
/// app.
///
/// The captures were taken with the server's clock at 2026-11-20T14:00:00.000Z (the deployed
/// backend's at 2026-11-20T03:01:39.899Z).
final class RealBackendShapesTests: XCTestCase {
    // MARK: Captured bodies (verbatim)

    private enum Captured {
        /// `verdict-leave-later.json`
        static let verdictLeaveLater = #"{"slots":[{"departAt":"2026-11-20T14:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T17:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T17:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T18:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T18:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T18:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T18:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T19:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T19:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1}],"verdict":{"action":"leave_later","waitMinutes":240,"reason":"Your deadline is 5 hours away, so there is no rush. Leaving in 4 hours still gets you there with 35 minutes to spare.","leaveNow":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"recommended":{"departAt":"2026-11-20T18:00:00.000Z","arriveAt":"2026-11-20T18:25:00.000Z","driveMinutes":25},"minutesSaved":0,"arrivalDelayMinutes":240,"confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"generatedAt":"2026-11-20T14:00:00.000Z","deadline":{"arriveBy":"2026-11-20T19:00:00.000Z","marginMinutes":35,"latestDeparture":{"departAt":"2026-11-20T18:30:00.000Z","arriveAt":"2026-11-20T18:55:00.000Z","driveMinutes":25}}},"source":{"baseline":"fixture","fallback":false,"live":false}}"#

        /// `verdict-leave-now.json`
        static let verdictLeaveNow = #"{"slots":[{"departAt":"2026-11-20T14:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T17:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1}],"verdict":{"action":"leave_now","waitMinutes":0,"reason":"Traffic won't improve much in the next 3 hours.","leaveNow":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"recommended":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"minutesSaved":0,"arrivalDelayMinutes":0,"confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"generatedAt":"2026-11-20T14:00:00.000Z","deadline":{"arriveBy":"2026-11-20T14:32:00.000Z","marginMinutes":7,"latestDeparture":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25}}},"source":{"baseline":"fixture","fallback":false,"live":false}}"#

        /// `verdict-late.json`
        static let verdictLate = #"{"slots":[{"departAt":"2026-11-20T14:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T17:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1}],"verdict":{"action":"leave_now","waitMinutes":0,"reason":"Leave now, you may be late by about 15 minutes.","leaveNow":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"recommended":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"minutesSaved":0,"arrivalDelayMinutes":0,"confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"generatedAt":"2026-11-20T14:00:00.000Z","lateByMinutes":15},"source":{"baseline":"fixture","fallback":false,"live":false}}"#

        /// `verdict-no-rush-too-far.json`
        static let verdictNoRushTooFar = #"{"slots":[{"departAt":"2026-11-20T14:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T14:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T14:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T15:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T15:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:15:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:40:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T16:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T16:45:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:10:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T17:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T17:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T17:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T18:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T18:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T18:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T18:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T19:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T19:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T19:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T19:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T20:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T20:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T20:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T20:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T21:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T21:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T21:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T21:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T22:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T22:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T22:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T22:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T23:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T23:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-20T23:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-20T23:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-21T00:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-21T00:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-21T00:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-21T00:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-21T01:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-21T01:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-21T01:30:00.000Z","driveMinutes":25,"arriveAt":"2026-11-21T01:55:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1},{"departAt":"2026-11-21T02:00:00.000Z","driveMinutes":25,"arriveAt":"2026-11-21T02:25:00.000Z","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","weatherFactor":1}],"verdict":{"action":"no_rush","waitMinutes":0,"reason":"Your deadline is 15 hours away, too far ahead to plan a departure. There is no need to leave yet. A plan will appear once the deadline is within 12 hours, in about 2 hr 35 min.","leaveNow":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"recommended":{"departAt":"2026-11-20T14:00:00.000Z","arriveAt":"2026-11-20T14:25:00.000Z","driveMinutes":25},"minutesSaved":0,"arrivalDelayMinutes":0,"confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"generatedAt":"2026-11-20T14:00:00.000Z"},"source":{"baseline":"fixture","fallback":false,"live":false}}"#

        /// `verdict-bad-request.json`
        static let verdictBadRequest = #"{"error":"bad_request","message":"body must have required property 'destination'"}"#

        /// `route.json`
        static let route = #"{"points":[{"lat":38.4088,"lng":-121.3716},{"lat":38.427825,"lng":-121.3781125},{"lat":38.44685,"lng":-121.384625},{"lat":38.465875,"lng":-121.3911375},{"lat":38.484899999999996,"lng":-121.39765},{"lat":38.503925,"lng":-121.4041625},{"lat":38.52295,"lng":-121.410675},{"lat":38.541975,"lng":-121.4171875},{"lat":38.561,"lng":-121.4237}],"distanceMiles":10.831868014827512,"source":"fixture","fallback":false}"#

        /// `devices-register.json`
        static let devicesRegister = #"{"deviceId":"a2f9db35-0f5b-4fda-a605-528b7b65f2c1","token":"a2f9db35-0f5b-4fda-a605-528b7b65f2c1.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","limits":{"planningHorizonMinutes":690,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50}}"#

        /// `push-update.json`
        static let pushUpdate = #"{"push":{"configured":true,"registered":true,"authorized":true}}"#

        /// `trips-sync.json`
        static let tripsSync = #"{"revision":1,"applied":true,"digest":"9d7bb33effef5bece5866c1d459a005149039123bc152274ae35bac67eb3f198","serverTime":"2026-11-20T14:00:00.000Z","limits":{"planningHorizonMinutes":690,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50},"push":{"configured":true,"registered":true,"authorized":true},"monitor":{"enabled":true,"dependable":true,"lastTickAt":"2026-11-20T14:00:00.000Z"},"trips":[{"id":"AAAAAAAA-0000-4000-8000-000000000003@2026-11-20","arriveBy":"2026-11-20T15:00:00.000Z","phase":"monitoring","recommendation":{"action":"leave_later","departAt":"2026-11-20T14:15:00.000Z","arriveAt":"2026-11-20T14:40:00.000Z","driveMinutes":25,"reason":"Your deadline is 1 hour away. Leaving in 15 minutes still gets you there with 20 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":20,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T12:15:00.000Z","startedAt":"2026-11-20T14:00:00.000Z","headsUpAt":"2026-11-20T12:45:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T15:00:00.000Z","nextCheckAt":"2026-11-20T14:15:00.000Z","lastAlert":{"kind":"heads_up","status":"queued","at":"2026-11-20T14:00:00.000Z"}},"lastError":null},{"id":"AAAAAAAA-0000-4000-8000-000000000001@2026-11-20","arriveBy":"2026-11-20T17:20:00.000Z","phase":"planned","recommendation":{"action":"leave_later","departAt":"2026-11-20T16:45:00.000Z","arriveAt":"2026-11-20T17:10:00.000Z","driveMinutes":25,"reason":"Your deadline is 3 hr 20 min away, so there is no rush. Leaving in 2 hr 45 min still gets you there with 10 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":10,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T14:45:00.000Z","startedAt":null,"headsUpAt":"2026-11-20T15:15:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T17:20:00.000Z","nextCheckAt":"2026-11-20T14:45:00.000Z","lastAlert":null},"lastError":null},{"id":"AAAAAAAA-0000-4000-8000-000000000002@2026-11-21","arriveBy":"2026-11-21T15:00:00.000Z","phase":"scheduled","recommendation":null,"noPlanReason":null,"planAvailableAt":"2026-11-21T03:30:00.000Z","monitoring":{"startsAt":null,"startedAt":null,"headsUpAt":null,"headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-21T15:00:00.000Z","nextCheckAt":"2026-11-21T03:30:00.000Z","lastAlert":null},"lastError":null}]}"#

        /// `trips-sync-retry.json`
        static let tripsSyncRetry = #"{"revision":1,"applied":false,"digest":"9d7bb33effef5bece5866c1d459a005149039123bc152274ae35bac67eb3f198","serverTime":"2026-11-20T14:00:00.000Z","limits":{"planningHorizonMinutes":690,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50},"push":{"configured":true,"registered":true,"authorized":true},"monitor":{"enabled":true,"dependable":true,"lastTickAt":"2026-11-20T14:00:00.000Z"},"trips":[{"id":"AAAAAAAA-0000-4000-8000-000000000003@2026-11-20","arriveBy":"2026-11-20T15:00:00.000Z","phase":"monitoring","recommendation":{"action":"leave_later","departAt":"2026-11-20T14:15:00.000Z","arriveAt":"2026-11-20T14:40:00.000Z","driveMinutes":25,"reason":"Your deadline is 1 hour away. Leaving in 15 minutes still gets you there with 20 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":20,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T12:15:00.000Z","startedAt":"2026-11-20T14:00:00.000Z","headsUpAt":"2026-11-20T12:45:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T15:00:00.000Z","nextCheckAt":"2026-11-20T14:15:00.000Z","lastAlert":{"kind":"heads_up","status":"queued","at":"2026-11-20T14:00:00.000Z"}},"lastError":null},{"id":"AAAAAAAA-0000-4000-8000-000000000001@2026-11-20","arriveBy":"2026-11-20T17:20:00.000Z","phase":"planned","recommendation":{"action":"leave_later","departAt":"2026-11-20T16:45:00.000Z","arriveAt":"2026-11-20T17:10:00.000Z","driveMinutes":25,"reason":"Your deadline is 3 hr 20 min away, so there is no rush. Leaving in 2 hr 45 min still gets you there with 10 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":10,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T14:45:00.000Z","startedAt":null,"headsUpAt":"2026-11-20T15:15:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T17:20:00.000Z","nextCheckAt":"2026-11-20T14:45:00.000Z","lastAlert":null},"lastError":null},{"id":"AAAAAAAA-0000-4000-8000-000000000002@2026-11-21","arriveBy":"2026-11-21T15:00:00.000Z","phase":"scheduled","recommendation":null,"noPlanReason":null,"planAvailableAt":"2026-11-21T03:30:00.000Z","monitoring":{"startsAt":null,"startedAt":null,"headsUpAt":null,"headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-21T15:00:00.000Z","nextCheckAt":"2026-11-21T03:30:00.000Z","lastAlert":null},"lastError":null}]}"#

        /// `trips-sync-conflict.json`
        static let tripsSyncConflict = #"{"error":"revision_conflict","message":"A different set of trips already used this revision. Send it again with a higher one.","revision":1}"#

        /// `trips-list.json`
        static let tripsList = #"{"revision":1,"applied":false,"digest":"9d7bb33effef5bece5866c1d459a005149039123bc152274ae35bac67eb3f198","serverTime":"2026-11-20T14:00:00.000Z","limits":{"planningHorizonMinutes":690,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50},"push":{"configured":true,"registered":true,"authorized":true},"monitor":{"enabled":true,"dependable":true,"lastTickAt":"2026-11-20T14:00:00.000Z"},"trips":[{"id":"AAAAAAAA-0000-4000-8000-000000000003@2026-11-20","arriveBy":"2026-11-20T15:00:00.000Z","phase":"monitoring","recommendation":{"action":"leave_later","departAt":"2026-11-20T14:15:00.000Z","arriveAt":"2026-11-20T14:40:00.000Z","driveMinutes":25,"reason":"Your deadline is 1 hour away. Leaving in 15 minutes still gets you there with 20 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":20,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T12:15:00.000Z","startedAt":"2026-11-20T14:00:00.000Z","headsUpAt":"2026-11-20T12:45:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T15:00:00.000Z","nextCheckAt":"2026-11-20T14:15:00.000Z","lastAlert":{"kind":"heads_up","status":"queued","at":"2026-11-20T14:00:00.000Z"}},"lastError":null},{"id":"AAAAAAAA-0000-4000-8000-000000000001@2026-11-20","arriveBy":"2026-11-20T17:20:00.000Z","phase":"planned","recommendation":{"action":"leave_later","departAt":"2026-11-20T16:45:00.000Z","arriveAt":"2026-11-20T17:10:00.000Z","driveMinutes":25,"reason":"Your deadline is 3 hr 20 min away, so there is no rush. Leaving in 2 hr 45 min still gets you there with 10 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":10,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T14:45:00.000Z","startedAt":null,"headsUpAt":"2026-11-20T15:15:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T17:20:00.000Z","nextCheckAt":"2026-11-20T14:45:00.000Z","lastAlert":null},"lastError":null},{"id":"AAAAAAAA-0000-4000-8000-000000000002@2026-11-21","arriveBy":"2026-11-21T15:00:00.000Z","phase":"scheduled","recommendation":null,"noPlanReason":null,"planAvailableAt":"2026-11-21T03:30:00.000Z","monitoring":{"startsAt":null,"startedAt":null,"headsUpAt":null,"headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-21T15:00:00.000Z","nextCheckAt":"2026-11-21T03:30:00.000Z","lastAlert":null},"lastError":null}]}"#

        /// `trip-detail.json`
        static let tripDetail = #"{"trip":{"id":"AAAAAAAA-0000-4000-8000-000000000003@2026-11-20","arriveBy":"2026-11-20T15:00:00.000Z","phase":"monitoring","recommendation":{"action":"leave_later","departAt":"2026-11-20T14:15:00.000Z","arriveAt":"2026-11-20T14:40:00.000Z","driveMinutes":25,"reason":"Your deadline is 1 hour away. Leaving in 15 minutes still gets you there with 20 minutes to spare.","confidence":"Medium","confidenceReason":"Live traffic is unavailable, so this uses typical conditions.","notes":[],"marginMinutes":20,"evaluatedAt":"2026-11-20T14:00:00.000Z","source":{"live":false,"baseline":"fixture","fallback":false},"stale":false},"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":"2026-11-20T12:15:00.000Z","startedAt":"2026-11-20T14:00:00.000Z","headsUpAt":"2026-11-20T12:45:00.000Z","headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T15:00:00.000Z","nextCheckAt":"2026-11-20T14:15:00.000Z","lastAlert":{"kind":"heads_up","status":"queued","at":"2026-11-20T14:00:00.000Z"}},"lastError":null},"serverTime":"2026-11-20T14:00:00.000Z","push":{"configured":true,"registered":true,"authorized":true},"limits":{"planningHorizonMinutes":690,"monitorLeadMinutes":120,"headsUpLeadMinutes":90,"meaningfulShiftMinutes":5,"maxTrips":50},"monitor":{"enabled":true,"dependable":true,"lastTickAt":"2026-11-20T14:00:00.000Z"}}"#

        /// `trip-not-found.json`
        static let tripNotFound = #"{"error":"not_found","message":"No such trip."}"#

        /// `departed-superseded.json`
        static let departedSuperseded = #"{"error":"superseded","message":"This trip was rescheduled."}"#

        /// `departed-ok.json`
        static let departedOk = #"{"trip":{"id":"AAAAAAAA-0000-4000-8000-000000000003@2026-11-20","arriveBy":"2026-11-20T15:00:00.000Z","phase":"departed","recommendation":null,"noPlanReason":null,"planAvailableAt":null,"monitoring":{"startsAt":null,"startedAt":"2026-11-20T14:00:00.000Z","headsUpAt":null,"headsUpSentAt":null,"leaveAlertSentAt":null,"endsAt":"2026-11-20T15:00:00.000Z","nextCheckAt":null,"lastAlert":null},"lastError":null}}"#

        /// `unauthorized.json`
        static let unauthorized = #"{"error":"unauthorized","message":"This device is not registered."}"#

        /// `unknown-route-404.json`
        static let unknownRoute404 = #"{"message":"Route GET:/nope not found","error":"Not Found","statusCode":404}"#

        /// `pushes.json`
        static let pushes = #"{"pushes":[{"sentAt":"2026-11-20T14:00:00.000Z","id":"8a39fb09-1fde-4b28-acbe-c8e95978464e","collapseId":"352f71bf-bda9-495b-b51d-858bd7bf47c0","environment":"sandbox","expiresAt":"2026-11-20T15:30:00.000Z","payload":{"aps":{"alert":{"body":"Plan to leave around 7:30 AM to arrive by 8:15 AM. We'll keep checking traffic.","title":"Heads up: Sample morning class"},"sound":"default","category":"WAIT_IT_OUT_TRIP","thread-id":"trip-5A170002-0000-4000-8000-0000000000A1@2026-11-20"},"kind":"heads_up","tripId":"5A170002-0000-4000-8000-0000000000A1@2026-11-20","arriveBy":"2026-11-20T16:15:00.000Z","departAt":"2026-11-20T15:30:00.000Z"}},{"sentAt":"2026-11-20T14:00:00.000Z","id":"961111a8-391e-41bf-87c0-7c6f44a6b201","collapseId":"3011d7ff-805e-4d9a-a7ce-60eb8f4871f4","environment":"sandbox","expiresAt":"2026-11-20T15:30:00.000Z","payload":{"aps":{"alert":{"body":"Plan to leave around 7:30 AM to arrive by 8:15 AM. We'll keep checking traffic.","title":"Heads up: Sample morning class"},"sound":"default","category":"WAIT_IT_OUT_TRIP","thread-id":"trip-5A170002-0000-4000-8000-0000000000A1@2026-11-20"},"kind":"heads_up","tripId":"5A170002-0000-4000-8000-0000000000A1@2026-11-20","arriveBy":"2026-11-20T16:15:00.000Z","departAt":"2026-11-20T15:30:00.000Z"}}]}"#

        /// `verdict-production-main.json`
        static let verdictProductionMain = #"{"slots":[{"departAt":"2026-11-20T03:01:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T03:24:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T03:16:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T03:39:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T03:31:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T03:54:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T03:46:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T04:09:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T04:01:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T04:24:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T04:16:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T04:39:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T04:31:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T04:54:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T04:46:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T05:09:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T05:01:39.899Z","driveMinutes":23,"arriveAt":"2026-11-20T05:24:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T05:16:39.899Z","driveMinutes":22,"arriveAt":"2026-11-20T05:38:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T05:31:39.899Z","driveMinutes":22,"arriveAt":"2026-11-20T05:53:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T05:46:39.899Z","driveMinutes":22,"arriveAt":"2026-11-20T06:08:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T06:01:39.899Z","driveMinutes":22,"arriveAt":"2026-11-20T06:23:39.899Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T06:30:00.000Z","driveMinutes":22,"arriveAt":"2026-11-20T06:52:00.000Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T07:00:00.000Z","driveMinutes":22,"arriveAt":"2026-11-20T07:22:00.000Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T07:30:00.000Z","driveMinutes":22,"arriveAt":"2026-11-20T07:52:00.000Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T08:00:00.000Z","driveMinutes":22,"arriveAt":"2026-11-20T08:22:00.000Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1},{"departAt":"2026-11-20T08:30:00.000Z","driveMinutes":22,"arriveAt":"2026-11-20T08:52:00.000Z","confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","weatherFactor":1}],"verdict":{"action":"leave_later","waitMinutes":238,"reason":"Your deadline is 4 hr 59 min away, so there is no rush. Leaving in 3 hr 58 min still gets you there with 39 minutes to spare.","leaveNow":{"departAt":"2026-11-20T03:01:39.899Z","arriveAt":"2026-11-20T03:24:39.899Z","driveMinutes":23},"recommended":{"departAt":"2026-11-20T07:00:00.000Z","arriveAt":"2026-11-20T07:22:00.000Z","driveMinutes":22},"minutesSaved":1,"arrivalDelayMinutes":237,"confidence":"High","confidenceReason":"Based on plenty of historical data and live traffic.","notes":[],"generatedAt":"2026-11-20T03:01:39.899Z","deadline":{"arriveBy":"2026-11-20T08:01:00.000Z","marginMinutes":39,"latestDeparture":{"departAt":"2026-11-20T07:30:00.000Z","arriveAt":"2026-11-20T07:52:00.000Z","driveMinutes":22}}}}"#
    }

    // MARK: Helpers

    /// An instant from its ISO-8601 text, parsed with a formatter of its own, independent of
    /// the code under test.
    private func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else {
            preconditionFailure("The fixture time \(text) must be an ISO-8601 instant")
        }
        return date
    }

    private var serverNow: Date {
        instant("2026-11-20T14:00:00.000Z")
    }

    private let fixtureSource = RecommendationSource(baseline: .fixture, usedFallback: false, hasLiveTraffic: false)
    private let classID = "AAAAAAAA-0000-4000-8000-000000000003@2026-11-20"
    private let laterID = "AAAAAAAA-0000-4000-8000-000000000001@2026-11-20"
    private let tomorrowID = "AAAAAAAA-0000-4000-8000-000000000002@2026-11-21"

    private func request(arriveBy: Date, id: String? = nil) throws -> CommuteRequest {
        let occurrence = try XCTUnwrap(OccurrenceID(rawValue: id ?? classID))
        let campus = CommutePlaces.sample.campus
        return CommuteRequest(
            occurrenceID: occurrence,
            origin: CommutePlaces.sample.home,
            destination: Destination(id: SampleLocation.demoCampus.destinationID, name: campus.name, coordinate: campus.coordinate),
            arriveBy: arriveBy
        )
    }

    /// What the live commute provider makes of one POST /verdict answer.
    private func verdict(
        _ body: String,
        status: Int = 200,
        now: Date,
        arriveBy: Date,
        planningHorizon: TimeInterval = BackendCommuteProvider.defaultPlanningHorizon
    ) async throws -> CommuteEstimateResponse {
        let clock = FixedWallClock(now)
        let transport = ScriptedHTTPTransport(.http(status: status, body: body))
        let provider = BackendCommuteProvider(
            client: TestBackend.client(transport: transport, clock: clock),
            clock: clock,
            planningHorizon: planningHorizon,
            describe: { TestBackend.iso($0) }
        )
        return try await provider.estimateCommute(for: try request(arriveBy: arriveBy))
    }

    private func recommendation(_ response: CommuteEstimateResponse, file: StaticString = #filePath, line: UInt = #line) throws -> DepartureRecommendation {
        guard case .recommendation(let recommendation) = response else {
            XCTFail("Expected a recommendation, got \(response)", file: file, line: line)
            throw TestStoreError()
        }
        return recommendation
    }

    /// The three trips of the captured snapshots, as the app would have sent them.
    private func capturedTrips() throws -> [MonitoredTrip] {
        let sent = [(classID, "2026-11-20T15:00:00.000Z"), (laterID, "2026-11-20T17:20:00.000Z"), (tomorrowID, "2026-11-21T15:00:00.000Z")]
        return try sent.map { id, arriveBy in
            MonitoredTrip(
                id: try XCTUnwrap(OccurrenceID(rawValue: id)),
                title: "Captured trip",
                origin: CommutePlaces.sample.home.coordinate,
                destination: CommutePlaces.sample.campus.coordinate,
                arriveBy: instant(arriveBy),
                timeZoneIdentifier: "America/Los_Angeles"
            )
        }
    }

    private struct Stack {
        let clock: ManualWallClock
        let transport: ScriptedHTTPTransport
        let credentials: InMemoryCredentialStore
        let session: BackendSession
        let client: BackendClient
    }

    /// A session at the captures' server time whose transport answers from `responder`.
    private func makeStack(push: FakePushRegistrar? = nil, responder: @escaping ScriptedHTTPTransport.Responder) -> Stack {
        let clock = ManualWallClock(serverNow)
        let transport = ScriptedHTTPTransport(responder: responder)
        let client = TestBackend.client(transport: transport, clock: clock)
        let credentials = InMemoryCredentialStore()
        let session = BackendSession(client: client, credentials: credentials, push: push, clock: clock)
        return Stack(clock: clock, transport: transport, credentials: credentials, session: session, client: client)
    }

    /// The real backend's answers to registration, the push report, and the first snapshot.
    private static let firstSynchronization: ScriptedHTTPTransport.Responder = { request in
        switch (request.method, request.path) {
        case ("POST", "/devices"):
            return .http(status: 201, body: Captured.devicesRegister)
        case ("PUT", "/devices/me/push"):
            return .http(status: 200, body: Captured.pushUpdate)
        case ("PUT", "/trips"):
            return .http(status: 200, body: Captured.tripsSync)
        default:
            return .http(status: 404, body: Captured.unknownRoute404)
        }
    }

    private func failure(_ work: () async throws -> Void) async -> TripMonitoringFailure? {
        do {
            try await work()
            return nil
        } catch {
            return error as? TripMonitoringFailure
        }
    }

    // MARK: POST /verdict

    func testARealLeaveLaterVerdictBecomesTheBackendsOwnRecommendation() async throws {
        let answer = try await verdict(Captured.verdictLeaveLater, now: serverNow, arriveBy: instant("2026-11-20T19:00:00.000Z"))
        let advised = try recommendation(answer)
        XCTAssertEqual(advised.advice, .leaveLater)
        XCTAssertEqual(advised.recommendedDeparture, instant("2026-11-20T18:00:00.000Z"), "The recommended slot, not the leave-now slot")
        XCTAssertEqual(advised.predictedArrival, instant("2026-11-20T18:25:00.000Z"))
        XCTAssertEqual(advised.reason, "Your deadline is 5 hours away, so there is no rush. Leaving in 4 hours still gets you there with 35 minutes to spare.")
        XCTAssertEqual(advised.confidence, .medium)
        XCTAssertEqual(advised.confidenceReason, "Live traffic is unavailable, so this uses typical conditions.")
        XCTAssertEqual(advised.notes, [])
        XCTAssertNil(advised.lateBy)
        XCTAssertEqual(advised.margin, 35 * 60, "deadline.marginMinutes, whose sibling latestDeparture is an object the app does not read")
        XCTAssertEqual(advised.generatedAt, serverNow)
        XCTAssertEqual(advised.receivedAt, serverNow)
        XCTAssertEqual(advised.source, fixtureSource)
        XCTAssertEqual(advised.source.label, "Test fixture traffic, not live")
        XCTAssertFalse(advised.isStale)
        XCTAssertFalse(advised.isMonitored)

        let state = DepartureState.resolving(answer, for: try request(arriveBy: instant("2026-11-20T19:00:00.000Z")))
        let calculation = try XCTUnwrap(state.calculation)
        XCTAssertEqual(calculation.leaveHome, instant("2026-11-20T18:00:00.000Z"))
        XCTAssertEqual(calculation.travelTime.seconds, 25 * 60)
        XCTAssertTrue(calculation.isSimulated, "Fixture traffic keeps its TEST DATA label")
    }

    func testARealLeaveNowVerdictUsesTheLeaveNowSlot() async throws {
        let answer = try await verdict(Captured.verdictLeaveNow, now: serverNow, arriveBy: instant("2026-11-20T14:32:00.000Z"))
        let advised = try recommendation(answer)
        XCTAssertEqual(advised.advice, .leaveNow)
        XCTAssertEqual(advised.recommendedDeparture, serverNow)
        XCTAssertEqual(advised.predictedArrival, instant("2026-11-20T14:25:00.000Z"))
        XCTAssertEqual(advised.reason, "Traffic won't improve much in the next 3 hours.")
        XCTAssertNil(advised.lateBy, "On time: no lateness is reported")
        XCTAssertEqual(advised.margin, 7 * 60)
        XCTAssertEqual(advised.confidence, .medium)
        XCTAssertEqual(advised.source, fixtureSource)
    }

    func testARealLateVerdictCarriesHowLate() async throws {
        let arriveBy = instant("2026-11-20T14:10:00.000Z")
        let answer = try await verdict(Captured.verdictLate, now: serverNow, arriveBy: arriveBy)
        let advised = try recommendation(answer)
        XCTAssertEqual(advised.advice, .leaveNow)
        XCTAssertEqual(advised.lateBy, 15 * 60)
        XCTAssertNil(advised.margin, "A late verdict has no deadline object, so no time to spare")
        XCTAssertEqual(advised.recommendedDeparture, serverNow)
        XCTAssertEqual(advised.predictedArrival, instant("2026-11-20T14:25:00.000Z"))
        XCTAssertEqual(advised.reason, "Leave now, you may be late by about 15 minutes.")

        let state = DepartureState.resolving(answer, for: try request(arriveBy: arriveBy))
        let calculation = try XCTUnwrap(state.calculation)
        XCTAssertTrue(calculation.isArrivalUnreachable)
        let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
        XCTAssertEqual(
            formatter.departureTimingText(for: calculation, at: serverNow),
            "Your ideal arrival is no longer reachable: leaving now you would arrive about 15 minutes late."
        )
    }

    func testARealNoRushVerdictIsNotYetInTheBackendsOwnWords() async throws {
        // 15 hours ahead. The provider's own reach is widened so that the question is asked
        // and the real "no rush" answer is what gets read.
        let answer = try await verdict(
            Captured.verdictNoRushTooFar,
            now: serverNow,
            arriveBy: instant("2026-11-21T05:00:00.000Z"),
            planningHorizon: 24 * 3_600
        )
        XCTAssertEqual(answer, .notYet(
            message: "Your deadline is 15 hours away, too far ahead to plan a departure. There is no need to leave yet. A plan will appear once the deadline is within 12 hours, in about 2 hr 35 min. Checked 2026-11-20T14:00:00.000Z.",
            askAgainAt: serverNow.addingTimeInterval(BackendCommuteProvider.noRushRecheckInterval)
        ))
        let state = DepartureState.resolving(answer, for: try request(arriveBy: instant("2026-11-21T05:00:00.000Z")))
        guard case .unavailable(.notYetPlannable) = state else {
            return XCTFail("A no-rush verdict is not a failure and not a leave-home time, got \(state)")
        }
    }

    func testARealBadRequestIsAServerFailureThatIsNotRetried() async throws {
        do {
            _ = try await verdict(Captured.verdictBadRequest, status: 400, now: serverNow, arriveBy: instant("2026-11-20T19:00:00.000Z"))
            XCTFail("A 400 is not an answer")
        } catch let failure as CommuteProviderFailure {
            XCTAssertEqual(failure.kind, .server(status: 400))
            XCTAssertFalse(failure.kind.isTransient, "Asking again would get the same refusal")
        }
        let clock = FixedWallClock(serverNow)
        let client = TestBackend.client(transport: ScriptedHTTPTransport(.http(status: 400, body: Captured.verdictBadRequest)), clock: clock)
        let reply = try await client.send(method: "POST", path: ["verdict"], body: Data("{}".utf8))
        XCTAssertEqual(reply.errorCode, "bad_request")
        XCTAssertEqual(reply.errorMessage, "body must have required property 'destination'")
    }

    func testARealAnswerOfTheDeployedBackendDecodesWithoutASource() async throws {
        // The deployed main branch predates the `source` field and stamps fractional seconds.
        let now = instant("2026-11-20T03:01:40.000Z")
        let answer = try await verdict(Captured.verdictProductionMain, now: now, arriveBy: instant("2026-11-20T08:01:00.000Z"))
        let advised = try recommendation(answer)
        XCTAssertEqual(advised.advice, .leaveLater)
        XCTAssertEqual(advised.recommendedDeparture, instant("2026-11-20T07:00:00.000Z"))
        XCTAssertEqual(advised.predictedArrival, instant("2026-11-20T07:22:00.000Z"))
        XCTAssertEqual(advised.reason, "Your deadline is 4 hr 59 min away, so there is no rush. Leaving in 3 hr 58 min still gets you there with 39 minutes to spare.")
        XCTAssertEqual(advised.confidence, .high)
        XCTAssertEqual(advised.confidenceReason, "Based on plenty of historical data and live traffic.")
        XCTAssertEqual(advised.margin, 39 * 60)
        XCTAssertNil(advised.lateBy)
        XCTAssertEqual(advised.generatedAt.timeIntervalSince1970, instant("2026-11-20T03:01:39.899Z").timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(advised.source, .unknown, "No source was reported, so none is claimed")
        XCTAssertEqual(advised.source.label, "Team backend")
        XCTAssertFalse(advised.source.hasLiveTraffic, "Live traffic is never claimed for a server that did not say so")

        let state = DepartureState.resolving(answer, for: try request(arriveBy: instant("2026-11-20T08:01:00.000Z")))
        let calculation = try XCTUnwrap(state.calculation)
        XCTAssertFalse(calculation.isSimulated)
        XCTAssertEqual(calculation.travelTime.seconds, 22 * 60)
    }

    // MARK: POST /route

    func testTheRealRouteAnswerBecomesGeometryWithItsSource() async throws {
        let clock = FixedWallClock(serverNow)
        let transport = ScriptedHTTPTransport(.http(status: 200, body: Captured.route))
        let provider = BackendRouteProvider(client: TestBackend.client(transport: transport, clock: clock))
        let route = try await provider.route(from: CommutePlaces.sample.home.coordinate, to: CommutePlaces.sample.campus.coordinate)
        XCTAssertEqual(route.points.count, 9)
        XCTAssertEqual(route.points.first, GeoCoordinate(latitude: 38.4088, longitude: -121.3716))
        XCTAssertEqual(route.points.last, GeoCoordinate(latitude: 38.561, longitude: -121.4237))
        XCTAssertEqual(route.distanceMiles, 10.831868014827512, accuracy: 0.000_000_001)
        XCTAssertEqual(route.sourceLabel, "Test fixture")
        XCTAssertTrue(route.isFixture)
        XCTAssertFalse(route.isFallback)
    }

    func testTheRealUnknownRouteAnswerMeansNotSupportedByThisServer() async throws {
        // Fastify's own 404: its "error" is "Not Found", which is not the API's "not_found".
        let clock = FixedWallClock(serverNow)
        let transport = ScriptedHTTPTransport(.http(status: 404, body: Captured.unknownRoute404))
        let client = TestBackend.client(transport: transport, clock: clock)
        let reply = try await client.send(method: "GET", path: ["nope"])
        XCTAssertEqual(reply.status, 404)
        XCTAssertEqual(reply.errorCode, "Not Found")
        XCTAssertEqual(reply.errorMessage, "Route GET:/nope not found")
        XCTAssertEqual(BackendSession.failure(for: reply), .unavailableOnServer)

        do {
            _ = try await BackendRouteProvider(client: client).route(from: CommutePlaces.sample.home.coordinate, to: CommutePlaces.sample.campus.coordinate)
            XCTFail("A server without the route is not a route")
        } catch {
            XCTAssertEqual(error as? RouteProviderFailure, .notSupported)
        }

        // On the device and trip endpoints it is a server that predates them.
        let stack = makeStack { request in
            request.path == "/devices" ? .http(status: 201, body: Captured.devicesRegister) : .http(status: 404, body: Captured.unknownRoute404)
        }
        let trips = try capturedTrips()
        let syncFailure = await failure { _ = try await stack.session.synchronize(trips) }
        XCTAssertEqual(syncFailure, .unavailableOnServer)
        var origins = await stack.credentials.origins()
        XCTAssertEqual(origins, ["https://backend.example"])
        try await stack.session.unregister(from: nil)
        origins = await stack.credentials.origins()
        XCTAssertEqual(origins, [], "There is nothing to remove on such a server, so the credential is dropped")
    }

    // MARK: Devices and trips

    func testTheRealRegistrationPushAndSnapshotAnswersAreUnderstood() async throws {
        let push = FakePushRegistrar(status: .authorized)
        let stack = makeStack(push: push, responder: Self.firstSynchronization)
        _ = await stack.session.updateDeviceToken(Data(repeating: 0xAB, count: 32))
        let trips = try capturedTrips()
        let snapshot = try await stack.session.synchronize(trips)

        // POST /devices: the device id, the credential, and the limits.
        let stored = try await stack.credentials.load(origin: "https://backend.example")
        let credential = try XCTUnwrap(stored)
        XCTAssertEqual(credential.deviceID, "a2f9db35-0f5b-4fda-a605-528b7b65f2c1")
        XCTAssertEqual(credential.token, "a2f9db35-0f5b-4fda-a605-528b7b65f2c1.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(credential.revision, 1)
        XCTAssertEqual(credential.serverRevision, 1)
        let sent = await stack.transport.requests
        XCTAssertEqual(sent.map { "\($0.method) \($0.path)" }, ["POST /devices", "PUT /devices/me/push", "PUT /trips"])
        XCTAssertEqual(sent.last?.headers["Authorization"], "Bearer \(credential.token)")

        // PUT /devices/me/push and the snapshot's own push, limits, and monitor objects.
        XCTAssertEqual(snapshot.push, PushDeliveryStatus(serverConfigured: true, deviceRegistered: true, authorized: true, lastFailure: nil))
        XCTAssertEqual(snapshot.limits, MonitoringLimits(planningHorizon: 690 * 60, monitorLead: 120 * 60, headsUpLead: 90 * 60, meaningfulShift: 5 * 60, maxTrips: 50))
        XCTAssertEqual(snapshot.monitor, MonitorHealth(enabled: true, dependable: true, lastTickAt: serverNow))
        XCTAssertEqual(snapshot.serverTime, serverNow)
        XCTAssertEqual(snapshot.acknowledgedAt, serverNow)
        XCTAssertNil(MonitoringObstacle.resolve(status: .active(acknowledgedAt: serverNow, tripCount: 3), push: snapshot.push, monitor: snapshot.monitor, permission: .authorized))
        let horizon = await stack.session.planningHorizon()
        XCTAssertEqual(horizon, 690 * 60)

        // The three trips, each in its own phase.
        XCTAssertEqual(Set(snapshot.trips.keys.map(\.rawValue)), [classID, laterID, tomorrowID])
        let monitored = try XCTUnwrap(snapshot.trips[try XCTUnwrap(OccurrenceID(rawValue: classID))])
        XCTAssertEqual(monitored.phase, .monitoring)
        XCTAssertEqual(monitored.arriveBy, instant("2026-11-20T15:00:00.000Z"))
        XCTAssertEqual(monitored.plan, MonitoredPlan(
            advice: .leaveLater,
            departAt: instant("2026-11-20T14:15:00.000Z"),
            arriveAt: instant("2026-11-20T14:40:00.000Z"),
            driveMinutes: 25,
            reason: "Your deadline is 1 hour away. Leaving in 15 minutes still gets you there with 20 minutes to spare.",
            confidence: .medium,
            confidenceReason: "Live traffic is unavailable, so this uses typical conditions.",
            notes: [],
            lateBy: nil,
            margin: 20 * 60,
            evaluatedAt: serverNow,
            source: fixtureSource,
            isStale: false
        ))
        XCTAssertNil(monitored.noPlanReason)
        XCTAssertNil(monitored.planAvailableAt)
        XCTAssertEqual(monitored.monitoringStartsAt, instant("2026-11-20T12:15:00.000Z"))
        XCTAssertEqual(monitored.monitoringStartedAt, serverNow)
        XCTAssertEqual(monitored.headsUpAt, instant("2026-11-20T12:45:00.000Z"))
        XCTAssertNil(monitored.headsUpSentAt, "Queued is not sent")
        XCTAssertNil(monitored.leaveAlertSentAt)
        XCTAssertEqual(monitored.lastAlert, TripAlert(kind: .headsUp, status: .queued, at: serverNow, reason: nil))
        XCTAssertEqual(monitored.endsAt, instant("2026-11-20T15:00:00.000Z"))
        XCTAssertEqual(monitored.nextCheckAt, instant("2026-11-20T14:15:00.000Z"))
        XCTAssertNil(monitored.lastErrorCode)
        XCTAssertNil(monitored.lastErrorAt)

        let planned = try XCTUnwrap(snapshot.trips[try XCTUnwrap(OccurrenceID(rawValue: laterID))])
        XCTAssertEqual(planned.phase, .planned)
        XCTAssertEqual(planned.plan?.advice, .leaveLater)
        XCTAssertEqual(planned.plan?.departAt, instant("2026-11-20T16:45:00.000Z"))
        XCTAssertEqual(planned.plan?.arriveAt, instant("2026-11-20T17:10:00.000Z"))
        XCTAssertEqual(planned.plan?.margin, 10 * 60)
        XCTAssertEqual(planned.plan?.reason, "Your deadline is 3 hr 20 min away, so there is no rush. Leaving in 2 hr 45 min still gets you there with 10 minutes to spare.")
        XCTAssertEqual(planned.monitoringStartsAt, instant("2026-11-20T14:45:00.000Z"))
        XCTAssertNil(planned.monitoringStartedAt)
        XCTAssertEqual(planned.headsUpAt, instant("2026-11-20T15:15:00.000Z"))
        XCTAssertNil(planned.lastAlert)
        XCTAssertEqual(planned.nextCheckAt, instant("2026-11-20T14:45:00.000Z"))

        let scheduled = try XCTUnwrap(snapshot.trips[try XCTUnwrap(OccurrenceID(rawValue: tomorrowID))])
        XCTAssertEqual(scheduled.phase, .scheduled)
        XCTAssertNil(scheduled.plan)
        XCTAssertEqual(scheduled.planAvailableAt, instant("2026-11-21T03:30:00.000Z"))
        XCTAssertNil(scheduled.monitoringStartsAt)
        XCTAssertNil(scheduled.headsUpAt)
        XCTAssertEqual(scheduled.endsAt, instant("2026-11-21T15:00:00.000Z"))
        XCTAssertEqual(scheduled.nextCheckAt, instant("2026-11-21T03:30:00.000Z"))

        // The monitored trip's plan is what the screens show; the others are asked directly.
        let answer = try await stack.session.answer(for: try request(arriveBy: instant("2026-11-20T15:00:00.000Z")))
        let shown = try recommendation(try XCTUnwrap(answer))
        XCTAssertTrue(shown.isMonitored)
        XCTAssertEqual(shown.recommendedDeparture, instant("2026-11-20T14:15:00.000Z"))
        XCTAssertEqual(shown.margin, 20 * 60)
        XCTAssertEqual(shown.source.label, "Test fixture traffic, not live")
        let direct = try await stack.session.answer(for: try request(arriveBy: instant("2026-11-20T17:20:00.000Z"), id: laterID))
        XCTAssertNil(direct, "Planned, not yet monitored")
    }

    func testTheRealRetryListAndDetailAnswersAreUnderstood() async throws {
        let stack = makeStack(responder: Self.firstSynchronization)
        let trips = try capturedTrips()
        let first = try await stack.session.synchronize(trips)
        let id = try XCTUnwrap(OccurrenceID(rawValue: classID))

        // The same snapshot sent again: "applied": false, and still exactly what was sent.
        await stack.transport.setResponder { request in
            switch (request.method, request.path) {
            case ("PUT", "/trips"):
                return .http(status: 200, body: Captured.tripsSyncRetry)
            case ("GET", "/trips"):
                return .http(status: 200, body: Captured.tripsList)
            default:
                return .http(status: 200, body: Captured.tripDetail)
            }
        }
        let retried = try await stack.session.synchronize(trips)
        XCTAssertEqual(retried.trips, first.trips, "An idempotent retry is acknowledged like the first answer")
        let resent = await stack.transport.requests.filter { $0.method == "PUT" && $0.path == "/trips" }
        XCTAssertEqual(resent.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 1], "The same body under the same revision")

        // GET /trips.
        let listed = try await stack.session.refresh()
        XCTAssertEqual(listed.trips, first.trips)
        XCTAssertEqual(listed.limits, first.limits)
        XCTAssertEqual(listed.monitor, first.monitor)
        XCTAssertEqual(listed.push, first.push)

        // GET /trips/:id carries the same trip inside "trip".
        let detail = try await stack.session.refreshTrip(id)
        XCTAssertEqual(detail, first.trips[id])
        let asked = await stack.transport.requests.last
        XCTAssertEqual(asked?.url.absoluteString, "https://backend.example/trips/AAAAAAAA-0000-4000-8000-000000000003%402026-11-20")

        // 404 "not_found": the server holds no such trip.
        await stack.transport.setReply(.http(status: 404, body: Captured.tripNotFound))
        let missing = try await stack.session.refreshTrip(id)
        XCTAssertNil(missing)
        let gone = await stack.session.markDeparted(id, arriveBy: instant("2026-11-20T15:00:00.000Z"))
        XCTAssertEqual(gone, .failure(.notMonitored))
    }

    func testTheRealDepartedAnswersAreUnderstood() async throws {
        let stack = makeStack(responder: Self.firstSynchronization)
        _ = try await stack.session.synchronize(try capturedTrips())
        let id = try XCTUnwrap(OccurrenceID(rawValue: classID))

        // 409 "superseded": the trip was rescheduled since.
        await stack.transport.setReply(.http(status: 409, body: Captured.departedSuperseded))
        let superseded = await stack.session.markDeparted(id, arriveBy: instant("2026-11-20T14:45:00.000Z"))
        XCTAssertEqual(superseded, .failure(.superseded))
        XCTAssertEqual(MonitoringText.departedSentence(.failed(.superseded)), "This trip was rescheduled; monitoring continues for the new time.")

        // 200: the trip in phase "departed", without a recommendation.
        await stack.transport.setReply(.http(status: 200, body: Captured.departedOk))
        let departed = await stack.session.markDeparted(id, arriveBy: instant("2026-11-20T15:00:00.000Z"))
        guard case .success(let state) = departed else {
            return XCTFail("Expected the departed trip, got \(departed)")
        }
        XCTAssertEqual(state.id, id)
        XCTAssertEqual(state.phase, .departed)
        XCTAssertNil(state.plan)
        XCTAssertEqual(state.arriveBy, instant("2026-11-20T15:00:00.000Z"))
        XCTAssertEqual(state.monitoringStartedAt, serverNow)
        XCTAssertNil(state.monitoringStartsAt)
        XCTAssertNil(state.nextCheckAt)
        XCTAssertNil(state.lastAlert)
        XCTAssertEqual(state.endsAt, instant("2026-11-20T15:00:00.000Z"))
        let body = await stack.transport.requests.last?.string("arriveBy")
        XCTAssertEqual(body, "2026-11-20T15:00:00.000Z")
        let answer = try await stack.session.answer(for: try request(arriveBy: instant("2026-11-20T15:00:00.000Z")))
        XCTAssertNil(answer, "A trip the user left is no longer answered from the server's plan")
    }

    func testTheRealRevisionConflictMovesPastTheServersRevision() async throws {
        // The server answers every snapshot with the captured conflict.
        let stack = makeStack { request in
            request.path == "/devices" ? .http(status: 201, body: Captured.devicesRegister) : .http(status: 409, body: Captured.tripsSyncConflict)
        }
        let conflict = await failure { _ = try await stack.session.synchronize(try self.capturedTrips()) }
        XCTAssertEqual(conflict, .server(status: 409), "A conflict that repeats is a failure, not a loop")
        let puts = await stack.transport.requests.filter { $0.method == "PUT" && $0.path == "/trips" }
        XCTAssertEqual(puts.compactMap { $0.jsonObject()["revision"] as? Int }, [1, 2], "Sent once more, under a revision above the one the server holds")
        let stored = try await stack.credentials.load(origin: "https://backend.example")
        XCTAssertEqual(stored?.serverRevision, 1, "The body's \"revision\" is the revision the server holds")
        XCTAssertEqual(stored?.revision, 2)

        let reply = try await stack.client.send(method: "PUT", path: ["trips"], body: Data("{}".utf8), bearerToken: "x")
        XCTAssertEqual(reply.status, 409)
        XCTAssertEqual(reply.errorCode, "revision_conflict")
        XCTAssertEqual(reply.errorMessage, "A different set of trips already used this revision. Send it again with a higher one.")
    }

    func testTheRealUnauthorizedAnswerDropsTheCredential() async throws {
        let stack = makeStack(responder: Self.firstSynchronization)
        _ = try await stack.session.synchronize(try capturedTrips())
        await stack.transport.setReply(.http(status: 401, body: Captured.unauthorized))

        let reading = await failure { _ = try await stack.session.refresh() }
        XCTAssertEqual(reading, .reregistered, "The model then registers anew and sends every trip again")
        let origins = await stack.credentials.origins()
        XCTAssertEqual(origins, [])

        let reply = try await stack.client.send(method: "GET", path: ["trips"], bearerToken: "x")
        XCTAssertEqual(reply.errorCode, "unauthorized")
        XCTAssertEqual(reply.errorMessage, "This device is not registered.")
        XCTAssertEqual(stack.client.failure(for: reply).kind, .unauthorized)
    }

    // MARK: The push the server sends

    func testTheRealPushPayloadOpensItsTripForTheArrivalItWasAbout() throws {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Captured.pushes.utf8)) as? [String: Any])
        let pushes = try XCTUnwrap(root["pushes"] as? [[String: Any]])
        XCTAssertEqual(pushes.count, 2)
        for push in pushes {
            XCTAssertEqual(push["environment"] as? String, "sandbox", "The environment the app reported for its development entitlement")
            let payload = try XCTUnwrap(push["payload"] as? [String: Any])
            var userInfo: [AnyHashable: Any] = [:]
            for (key, value) in payload {
                userInfo[key] = value
            }

            // The system's part: a visible alert in the app's category.
            let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
            XCTAssertEqual(aps["category"] as? String, TripNotificationPayload.categoryIdentifier)
            let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
            XCTAssertEqual(alert["title"] as? String, "Heads up: Sample morning class")
            XCTAssertEqual(alert["body"] as? String, "Plan to leave around 7:30 AM to arrive by 8:15 AM. We'll keep checking traffic.")
            XCTAssertNil(aps["content-available"], "A visible alert, not a background push")

            // The app's part: the trip and the arrival time the alert was about.
            let tripID = "5A170002-0000-4000-8000-0000000000A1@2026-11-20"
            XCTAssertEqual(TripNotificationPayload.tripID(from: userInfo), tripID)
            XCTAssertNotNil(OccurrenceID(rawValue: tripID), "The trip id is one of the app's occurrence ids")
            XCTAssertEqual(TripNotificationPayload.arriveBy(from: userInfo), instant("2026-11-20T16:15:00.000Z"))

            let opened = TripNotificationPayload.response(userInfo: userInfo, actionIdentifier: "open", openActionIdentifier: "open")
            XCTAssertEqual(opened, TripNotificationResponse(tripID: tripID, action: .open, arriveBy: instant("2026-11-20T16:15:00.000Z")))
            let left = TripNotificationPayload.response(userInfo: userInfo, actionIdentifier: TripNotificationPayload.leftActionIdentifier, openActionIdentifier: "open")
            XCTAssertEqual(left, TripNotificationResponse(tripID: tripID, action: .left, arriveBy: instant("2026-11-20T16:15:00.000Z")))
            XCTAssertNil(TripNotificationPayload.response(userInfo: userInfo, actionIdentifier: "dismiss", openActionIdentifier: "open"))
        }
    }
}
