import XCTest
@testable import WaitItOutUX

/// Stage S1: every sentence a backend recommendation and its failure states put on screen,
/// rendered in en_US and the Pacific zone. The local formula is never claimed for a backend
/// answer, a kept recommendation is always marked out of date, and the demo sentences are
/// unchanged. Times are matched on digits because iOS 17 puts a narrow no-break space before
/// AM and PM.
///
/// Fixture: ideal arrival Mon 2026-10-26 8:15 AM PDT, recommended departure 7:15 AM, predicted
/// arrival 8:00 AM, checked at 6:00 AM.
final class RecommendationTextTests: XCTestCase {
    private let formatter = OccurrenceFormatter(calculator: TestFixtures.pacificCalculator(), locale: TestFixtures.enUS)
    private let sixAM = TestFixtures.date(2026, 10, 26, 6, 0)
    private let sevenFifteen = TestFixtures.date(2026, 10, 26, 7, 15)
    private let eight = TestFixtures.date(2026, 10, 26, 8, 0)
    private let eightFifteen = TestFixtures.date(2026, 10, 26, 8, 15)
    private let backendReason = "Your deadline is 2 hr 15 min away, so there is no rush. Leaving at 7:15 AM still gets you there with 15 minutes to spare."

    private func calculation(
        advice: DepartureAdvice = .leaveLater,
        departure: Date? = nil,
        arrival: Date? = nil,
        notes: [String] = [],
        lateBy: TimeInterval? = nil,
        margin: TimeInterval? = 15 * 60,
        confidenceReason: String = "Based on plenty of historical data and live traffic.",
        generatedAt: Date? = nil,
        source: RecommendationSource = TestBackend.liveSource
    ) throws -> DepartureCalculation {
        try DepartureCalculation.make(
            idealArrival: eightFifteen,
            recommendation: TestBackend.recommendation(
                advice: advice,
                departure: departure ?? sevenFifteen,
                arrival: arrival ?? eight,
                reason: backendReason,
                confidenceReason: confidenceReason,
                notes: notes,
                lateBy: lateBy,
                margin: margin,
                generatedAt: generatedAt ?? sixAM,
                source: source
            )
        ).get()
    }

    private func demoCalculation() throws -> DepartureCalculation {
        try DepartureCalculation.make(
            idealArrival: eightFifteen,
            estimate: testEstimate(minutes: 60, at: sixAM, label: "Test commute (simulated, not live traffic)")
        ).get()
    }

    // MARK: A current recommendation

    func testTheLeaveHomeRowShowsTheRecommendedDeparture() throws {
        let planned = try calculation()
        XCTAssertEqual(formatter.leaveHomeValueText(for: planned), formatter.clockTime(sevenFifteen))
        XCTAssertTrue(formatter.leaveHomeValueText(for: planned).contains("7:15"))

        let sevenTwenty = TestFixtures.date(2026, 10, 26, 7, 20)
        let leaveNow = try calculation(advice: .leaveNow, departure: sevenTwenty, arrival: TestFixtures.date(2026, 10, 26, 8, 5), generatedAt: sevenTwenty)
        XCTAssertEqual(formatter.leaveHomeValueText(for: leaveNow), "Leave now, as of \(formatter.clockTime(sevenTwenty))")

        // The demo value is the calculated time, as before.
        let demo = try demoCalculation()
        XCTAssertEqual(formatter.leaveHomeValueText(for: demo), formatter.leaveHomeText(for: demo))
    }

    func testThePredictionReplacesTheLocalFormula() throws {
        let planned = try calculation()
        let line = formatter.departureFormulaText(for: planned)
        XCTAssertEqual(line, "Predicted arrival \(formatter.clockTime(eight)) after about 45 minutes of driving")
        XCTAssertFalse(line.contains("minus"), "No local arithmetic is claimed for a backend answer")
        XCTAssertFalse(line.contains("Ideal arrival"), line)

        XCTAssertTrue(formatter.departureFormulaText(for: try demoCalculation()).hasSuffix("minus 1 hour of travel"), "The demo formula is unchanged")
    }

    func testTheBackendsReasonIsShownOnlyWhileItIsCurrent() throws {
        let planned = try calculation()
        XCTAssertEqual(formatter.recommendationReasonText(for: planned, at: sixAM), backendReason, "Verbatim")
        XCTAssertEqual(formatter.recommendationReasonText(for: planned, at: sixAM.addingTimeInterval(120)), backendReason)
        // Older than two minutes: the relative sentence is replaced by the absolute fact.
        XCTAssertEqual(
            formatter.recommendationReasonText(for: planned, at: sixAM.addingTimeInterval(121)),
            "About 15 minutes to spare before your ideal arrival."
        )
        let noMargin = try calculation(margin: nil)
        XCTAssertNil(formatter.recommendationReasonText(for: noMargin, at: sixAM.addingTimeInterval(600)))
        let late = try calculation(advice: .leaveNow, lateBy: 40 * 60, margin: 15 * 60)
        XCTAssertNil(formatter.recommendationReasonText(for: late, at: sixAM.addingTimeInterval(600)), "No time to spare is claimed for a late trip")
        XCTAssertNil(formatter.recommendationReasonText(for: try demoCalculation(), at: sixAM), "A demo estimate has no backend reason")
    }

    func testTheSourceLineNamesTheBackendsSourceItsStampAndItsAge() throws {
        let planned = try calculation()
        XCTAssertEqual(
            formatter.departureSourceText(for: planned, at: sixAM),
            "Live traffic (TomTom) via the team backend, checked \(formatter.clockTime(sixAM)), just now"
        )
        XCTAssertEqual(
            formatter.departureSourceText(for: planned, at: sixAM.addingTimeInterval(12 * 60)),
            "Live traffic (TomTom) via the team backend, checked \(formatter.clockTime(sixAM)), 12 minutes ago"
        )
        let fallback = try calculation(source: RecommendationSource(baseline: .pems, usedFallback: true, hasLiveTraffic: false))
        XCTAssertTrue(formatter.departureSourceText(for: fallback).hasPrefix("Historical traffic (PeMS fallback); TomTom unavailable, checked "))
        let fixture = try calculation(source: RecommendationSource(baseline: .fixture, usedFallback: false, hasLiveTraffic: false))
        XCTAssertTrue(formatter.departureSourceText(for: fixture).hasPrefix("Test fixture traffic, not live, checked "))
        XCTAssertFalse(formatter.departureSourceText(for: planned).contains("estimated"), "Not worded as a local estimate")

        // The demo source line is unchanged.
        XCTAssertTrue(formatter.departureSourceText(for: try demoCalculation()).hasPrefix("Test commute (simulated, not live traffic), estimated "))
    }

    func testConfidenceIsShownWithItsReason() throws {
        XCTAssertEqual(
            formatter.recommendationConfidenceText(for: try calculation()),
            "High confidence: Based on plenty of historical data and live traffic."
        )
        XCTAssertEqual(formatter.recommendationConfidenceText(for: try calculation(confidenceReason: "")), "High confidence")
        XCTAssertNil(formatter.recommendationConfidenceText(for: try demoCalculation()))
    }

    // MARK: Leave now and late

    func testLeaveNowIsNeverGivenTheLocalMayMissWarning() throws {
        let sevenTwenty = TestFixtures.date(2026, 10, 26, 7, 20)
        let leaveNow = try calculation(advice: .leaveNow, departure: sevenTwenty, arrival: TestFixtures.date(2026, 10, 26, 8, 5), generatedAt: sevenTwenty)
        for minute in 0...4 {
            let now = sevenTwenty.addingTimeInterval(TimeInterval(minute) * 60)
            XCTAssertNil(formatter.departureTimingText(for: leaveNow, at: now), "Nothing alarming for an on-time leave now, minute \(minute)")
            let spoken = formatter.departureAccessibilityLabel(for: leaveNow, at: now)
            XCTAssertTrue(spoken.hasPrefix("Leave now, as of 7:20"), spoken)
            XCTAssertFalse(spoken.contains("may miss"), spoken)
            XCTAssertFalse(spoken.contains("has passed"), spoken)
        }

        // A planned time that has just passed is handed back to the backend, not judged here.
        let planned = try calculation()
        XCTAssertNil(formatter.departureTimingText(for: planned, at: TestFixtures.date(2026, 10, 26, 7, 30)))

        // The demo warning is unchanged.
        let demoWarning = try XCTUnwrap(formatter.departureTimingText(for: try demoCalculation(), at: TestFixtures.date(2026, 10, 26, 7, 30)))
        XCTAssertTrue(demoWarning.contains("may miss"), demoWarning)
    }

    func testAnUnreachableArrivalIsSaidInTheBackendsTerms() throws {
        let late = try calculation(advice: .leaveNow, departure: sixAM, arrival: eightFifteen.addingTimeInterval(40 * 60), lateBy: 40 * 60, margin: nil)
        XCTAssertEqual(
            formatter.departureTimingText(for: late, at: sixAM),
            "Your ideal arrival is no longer reachable: leaving now you would arrive about 40 minutes late."
        )
        let spoken = formatter.departureAccessibilityLabel(for: late, at: sixAM)
        XCTAssertTrue(spoken.hasSuffix("you would arrive about 40 minutes late."), spoken)
        XCTAssertFalse(spoken.contains("may miss"), spoken)

        let longer = try calculation(advice: .leaveNow, departure: sixAM, arrival: eightFifteen.addingTimeInterval(65 * 60), lateBy: 65 * 60, margin: nil)
        XCTAssertTrue(formatter.departureTimingText(for: longer, at: sixAM)?.hasSuffix("about 1 hour 5 minutes late.") ?? false)

        // Once the arrival target itself has passed, that is what is said.
        let after = try XCTUnwrap(formatter.departureTimingText(for: late, at: eightFifteen.addingTimeInterval(60)))
        XCTAssertTrue(after.contains("arrival target has passed"), after)
    }

    // MARK: Out of date and failed

    func testRefreshingARecommendationSaysTheBackendIsCheckedAgain() throws {
        let planned = try calculation()
        XCTAssertEqual(formatter.departureMessage(for: .refreshing(planned)), "Out of date: checking the backend again\u{2026}")
        XCTAssertEqual(
            formatter.staleDepartureAccessibilityLabel(for: planned),
            "Leave home at \(formatter.clockTime(sevenFifteen)), out of date. Checking the backend again."
        )
        let fixture = try calculation(source: RecommendationSource(baseline: .fixture, usedFallback: false, hasLiveTraffic: false))
        XCTAssertTrue(formatter.staleDepartureAccessibilityLabel(for: fixture).hasSuffix("Test fixture traffic, not live."))
        XCTAssertFalse(formatter.staleDepartureAccessibilityLabel(for: planned).contains("Simulated"), "A live answer is not called simulated")

        // The demo wording is unchanged.
        let demo = try demoCalculation()
        XCTAssertTrue(formatter.departureMessage(for: .refreshing(demo))?.hasPrefix("Out of date: updating the commute estimate from ") ?? false)
        XCTAssertTrue(formatter.staleDepartureAccessibilityLabel(for: demo).contains("Updating the commute estimate"))
    }

    func testAKeptRecommendationIsMarkedOutOfDateWithTheReason() throws {
        let planned = try calculation()
        let checked = formatter.clockTime(sixAM)
        XCTAssertEqual(
            formatter.departureMessage(for: .stale(planned, .provider(.offline))),
            "Could not refresh since \(checked): The backend could not be reached. Check the connection. Showing the last recommendation, which may be wrong."
        )
        XCTAssertEqual(
            formatter.departureMessage(for: .stale(planned, .provider(.timedOut))),
            "Could not refresh since \(checked): The backend did not answer in time. It may be waking up; this is retried automatically. Showing the last recommendation, which may be wrong."
        )
        XCTAssertEqual(
            formatter.departureMessage(for: .stale(planned, .staleServerData)),
            "Could not refresh since \(checked): The server could not re-check traffic on schedule. Showing the last recommendation, which may be wrong."
        )
        XCTAssertEqual(
            formatter.departureMessage(for: .stale(planned, .providerFailed)),
            "Could not refresh since \(checked): The request failed. Showing the last recommendation, which may be wrong."
        )
        let spoken = formatter.unrefreshedDepartureAccessibilityLabel(for: planned)
        XCTAssertEqual(spoken, "Leave home at \(formatter.clockTime(sevenFifteen)), out of date. The last recommendation could not be refreshed and may be wrong.")
    }

    func testEveryBackendFailureHasItsOwnSentence() {
        func message(_ kind: CommuteProviderFailure.Kind) -> String? {
            formatter.departureMessage(for: .error(.provider(kind)))
        }
        XCTAssertEqual(message(.notConfigured), "No backend address is set. Add one in Settings, Data source. No leave-home time is shown.")
        XCTAssertEqual(message(.offline), "The backend could not be reached. Check the connection. No leave-home time is shown.")
        XCTAssertEqual(message(.timedOut), "The backend did not answer in time. It may be waking up; this is retried automatically. No leave-home time is shown.")
        XCTAssertEqual(message(.routingUnavailable), "The routing service could not plan this trip right now. No leave-home time is shown.")
        XCTAssertEqual(message(.server(status: 503)), "The backend had a problem (HTTP 503). No leave-home time is shown.")
        XCTAssertEqual(message(.invalidResponse), "The backend's answer could not be read. No leave-home time is shown.")
        XCTAssertEqual(message(.unauthorized), "The backend did not accept this device. No leave-home time is shown.")
        XCTAssertEqual(
            formatter.departureMessage(for: .error(.staleServerData)),
            "The server could not re-check traffic on schedule. No leave-home time is shown."
        )
        // The prototype's two failure sentences are unchanged.
        XCTAssertEqual(formatter.departureMessage(for: .error(.providerFailed)), "The commute estimate could not be loaded, so no leave-home time is shown.")
        XCTAssertEqual(
            formatter.departureMessage(for: .error(.invalidEstimate(.missingSourceLabel))),
            "The commute estimate was not usable (no source label), so it was ignored and no leave-home time is shown."
        )
        XCTAssertEqual(formatter.departureFailureSentence(.invalidEstimate(.travelTime(.notPositive))), "The answer was not usable (zero or negative travel time).")
    }

    func testANotYetAnswerIsShownInItsOwnWords() {
        let message = "The traffic forecast reaches about 11.5 hours ahead. A leave-home time will appear after Mon, Oct 26, 7:30 AM."
        let state = DepartureState.unavailable(.notYetPlannable(message: message, askAgainAt: sixAM.addingTimeInterval(5_400)))
        XCTAssertEqual(formatter.departureMessage(for: state), message)
        XCTAssertEqual(
            formatter.reminderGapText(.estimateUnavailable(.notYetPlannable(message: message, askAgainAt: sixAM)), trip: nil),
            "No reminder preview for the next trip: there is no leave-home time for it yet."
        )
    }

    // MARK: Reminder text

    func testAReminderForARecommendationNamesTheSourceInsteadOfAFormula() throws {
        let planned = try calculation()
        let message = formatter.reminderMessage(for: planned, destinationName: "Sample campus")
        XCTAssertEqual(
            message,
            "Leave home at \(formatter.clockTime(sevenFifteen)) to reach Sample campus by your ideal arrival, \(formatter.clockTime(eightFifteen)). Live traffic (TomTom) via the team backend."
        )
        XCTAssertFalse(message.contains("Travel time"), "No local travel-time claim")
        XCTAssertFalse(message.contains("simulated"), message)

        let demo = formatter.reminderMessage(for: try demoCalculation(), destinationName: "Sample campus")
        XCTAssertTrue(demo.hasSuffix("Travel time 1 hour (simulated test estimate, not live traffic)."), "The demo reminder is unchanged: \(demo)")
    }

    // MARK: Mode-dependent explanations

    func testTheDemoExplanationsAreThePrototypesOwnWords() {
        XCTAssertEqual(
            DepartureWording.detailFooter(usesLiveBackend: false),
            "Calculated automatically for the trip from home: ideal arrival minus the commute estimate. Nothing else is subtracted, and it cannot be edited. Change the ideal arrival, home and campus, or the Settings Prototype testing values to change it."
        )
        XCTAssertEqual(
            DepartureWording.editorArrivalFooter(usesLiveBackend: false, isRecurring: false),
            "Set this after the activity time. It already includes any study, parking, or buffer time. Leave home is calculated from it automatically, ideal arrival minus the commute, and cannot be edited."
        )
        XCTAssertEqual(
            DepartureWording.editorArrivalFooter(usesLiveBackend: false, isRecurring: true),
            "Set this after the activity time. It already includes any study, parking, or buffer time. Leave home is calculated from it automatically, ideal arrival minus the commute, and cannot be edited. The same calculation applies to every occurrence of the series."
        )
        XCTAssertEqual(DepartureWording.retryHint(usesLiveBackend: false), "Asks the commute provider for the estimate again")
    }

    func testTheLiveExplanationsNameTheBackendAndClaimNoLocalFormula() {
        let texts = [
            DepartureWording.detailFooter(usesLiveBackend: true),
            DepartureWording.editorArrivalFooter(usesLiveBackend: true, isRecurring: false),
            DepartureWording.editorArrivalFooter(usesLiveBackend: true, isRecurring: true),
            DepartureWording.retryHint(usesLiveBackend: true)
        ]
        for text in texts {
            XCTAssertTrue(text.contains("team backend"), text)
            XCTAssertFalse(text.contains("minus"), "No local formula: \(text)")
            XCTAssertFalse(text.contains("Prototype testing"), text)
            XCTAssertFalse(text.contains("commute estimate"), text)
        }
        XCTAssertTrue(texts[0].contains("margin of at least 10 minutes"), texts[0])
        XCTAssertTrue(texts[0].contains("the app adds none"), texts[0])
        XCTAssertTrue(texts[1].contains("the app adds no margin of its own"), texts[1])
        XCTAssertTrue(texts[2].hasSuffix("Every occurrence of the series gets its own recommendation."), texts[2])
        XCTAssertEqual(texts[3], "Asks the team backend for the recommendation again")
    }

    func testTheNewDeparturePartsHaveStableIdentifiers() {
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.mapNextTripDeparture, .reason), "map.nextTripDeparture.reason")
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.calendarDetailDeparture, .confidence), "calendar.detailDeparture.confidence")
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.editorDeparture, .notes), "editor.departure.notes")
        // The step 0005 parts are unchanged.
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.editorDeparture, .leaveHome), "editor.departure.leaveHome")
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.editorDeparture, .status), "editor.departure.status")
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.editorDeparture, .message), "editor.departure.message")
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.editorDeparture, .source), "editor.departure.source")
        XCTAssertEqual(AccessibilityID.departure(AccessibilityID.editorDeparture, .retry), "editor.departure.retry")
    }
}
