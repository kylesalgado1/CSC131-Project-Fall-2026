import Foundation

/// How old a commute estimate is (step 0006). Pure: the caller passes `now`.
///
/// An estimate older than its lifetime is stale. While its trip can still be made (the ideal
/// arrival is ahead), the model asks the provider again on the next refresh, such as the Map's
/// minute tick, and keeps showing the old time marked out of date until the answer arrives.
///
/// A demo estimate lives for `lifetime`. A backend recommendation follows the backend's own
/// rhythm: far-off departures sit on a fixed half-hour grid and are asked less often, a nearby
/// departure is asked again exactly one backend slot after it was last asked, a "leave now"
/// answer is kept for a fixed few minutes, a planned time that has just passed is handed over
/// to the backend once, and a monitored plan is not re-asked from here while its departure is
/// ahead, because the server pushes its changes.
public enum EstimateFreshness {
    /// How long an estimate counts as current: 10 minutes.
    public static let lifetime: TimeInterval = 10 * 60
    /// How long a backend recommendation whose departure is far off counts as current: 30 minutes.
    public static let farLifetime: TimeInterval = 30 * 60
    /// A recommended departure further ahead than this (3 hours) is "far off".
    public static let farDepartureLead: TimeInterval = 3 * 3_600
    /// How long a backend recommendation for a nearby departure counts as current: one backend
    /// slot (15 minutes) minus half a minute tick, measured from when it was asked.
    ///
    /// Inside three hours the backend's candidate departures are the ask time plus whole
    /// slots, so the answer depends on when the question is put: asked at arbitrary moments,
    /// the leave-home time would jump by up to a slot with traffic unchanged. Refreshes run on
    /// whole-minute ticks, so with this value the fifteenth tick after an ask (900 seconds
    /// later) asks again, exactly one slot on, on the same grid of departures, and the time
    /// moves only when traffic does. A plain 900 seconds would be missed by that tick and met
    /// by the sixteenth, which would shift the grid a minute each time.
    ///
    /// What remains: an ask at a moment of its own (the first one, a return to the foreground
    /// after the lifetime, Try Again, the editor's preview) starts a new grid and can move the
    /// time once.
    public static let nearLifetime: TimeInterval = 15 * 60 - 30
    /// How long a backend "leave now" answer counts as current: a fixed 5 minutes.
    public static let leaveNowLifetime: TimeInterval = 5 * 60
    /// Once a planned backend departure has passed, an answer at least this old (60 seconds) is
    /// asked again, so the backend can say "leave now" or "late".
    public static let passedDepartureLifetime: TimeInterval = 60

    /// Elapsed seconds since `estimatedAt`; a timestamp in the future counts as zero.
    public static func age(of estimatedAt: Date, at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(estimatedAt))
    }

    public static func isStale(_ estimatedAt: Date, at now: Date) -> Bool {
        age(of: estimatedAt, at: now) >= lifetime
    }

    /// How long `calculation` counts as current at `now`. A demo estimate: `lifetime`. A
    /// backend recommendation: `leaveNowLifetime` for "leave now", `farLifetime` while its
    /// departure is more than `farDepartureLead` ahead, `nearLifetime` otherwise.
    public static func lifetime(for calculation: DepartureCalculation, at now: Date) -> TimeInterval {
        guard let recommendation = calculation.recommendation else { return lifetime }
        if recommendation.advice == .leaveNow { return leaveNowLifetime }
        if calculation.leaveHome.timeIntervalSince(now) > farDepartureLead { return farLifetime }
        return nearLifetime
    }

    /// True when a successful calculation should be refreshed at `now`: it is older than its
    /// lifetime and its arrival target is still ahead. Estimates for trips whose arrival has
    /// passed are kept.
    ///
    /// A monitored plan is not refreshed from here while its departure is ahead. Once that has
    /// passed the server no longer re-checks it, so it is handed back like any other answer.
    /// A planned backend departure that has passed is refreshed once it is
    /// `passedDepartureLifetime` old. The age of a nearby backend departure is measured from
    /// `askedAt`, when the model asked for it (see `nearLifetime`), so a slow answer does not
    /// shift the next ask; every other age is measured from when the answer arrived.
    public static func needsRefresh(_ calculation: DepartureCalculation, at now: Date, askedAt: Date? = nil) -> Bool {
        guard now < calculation.idealArrival else { return false }
        var elapsed = age(of: calculation.estimatedAt, at: now)
        if let recommendation = calculation.recommendation {
            if recommendation.isMonitored, now <= calculation.leaveHome { return false }
            if recommendation.advice != .leaveNow, now > calculation.leaveHome, elapsed >= passedDepartureLifetime {
                return true
            }
            let isNear = recommendation.advice != .leaveNow
                && calculation.leaveHome.timeIntervalSince(now) <= farDepartureLead
            if isNear, let askedAt {
                elapsed = age(of: askedAt, at: now)
            }
        }
        return elapsed >= lifetime(for: calculation, at: now)
    }
}
