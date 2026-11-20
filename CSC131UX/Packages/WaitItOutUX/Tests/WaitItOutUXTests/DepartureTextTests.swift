import XCTest
@testable import WaitItOutUX

/// Step 0005: the read-only leave-home text the detail sheet, the editor, and the Map card
/// show, rendered in en_US and the Pacific zone. Times are matched on digits because iOS 17
/// puts a narrow no-break space before AM and PM.
final class DepartureTextTests: XCTestCase {
    private let calculator = TestFixtures.pacificCalculator()
    private lazy var formatter = OccurrenceFormatter(calculator: calculator, locale: TestFixtures.enUS)

    private func calculation(arrival: Date, minutes: Double, label: String = "Test commute (simulated, not live traffic)") throws -> DepartureCalculation {
        let estimate = testEstimate(minutes: minutes, at: TestFixtures.fridayNoon, label: label)
        switch DepartureCalculation.make(idealArrival: arrival, estimate: estimate) {
        case .success(let calculation):
            return calculation
        case .failure(let issue):
            XCTFail("Unexpected invalid estimate: \(issue)")
            throw issue
        }
    }

    func testSameDayLeaveHomeShowsTheTimeOnly() throws {
        let morning = try calculation(arrival: TestFixtures.date(2026, 10, 26, 8, 15), minutes: 60)
        let text = formatter.leaveHomeText(for: morning)
        XCTAssertTrue(text.contains("7:15"), text)
        XCTAssertTrue(text.contains("AM"), text)
        XCTAssertFalse(text.contains(" on "), "Leaving on the arrival day needs no date: \(text)")

        let lab = try calculation(arrival: TestFixtures.date(2026, 10, 27, 11, 15), minutes: 60)
        XCTAssertTrue(formatter.leaveHomeText(for: lab).contains("10:15"))
    }

    func testPreviousDayLeaveHomeCarriesItsDate() throws {
        let afterMidnight = try calculation(arrival: TestFixtures.date(2026, 10, 27, 0, 30), minutes: 60)
        let text = formatter.leaveHomeText(for: afterMidnight)
        XCTAssertTrue(text.contains("11:30"), text)
        XCTAssertTrue(text.contains("PM"), text)
        XCTAssertTrue(text.contains("on Monday, October 26"), text)
    }

    func testFormulaAndSourceNameTheArrivalTheTravelTimeAndTheSimulatedSource() throws {
        let morning = try calculation(arrival: TestFixtures.date(2026, 10, 26, 8, 15), minutes: 60)
        let formula = formatter.departureFormulaText(for: morning)
        XCTAssertTrue(formula.hasPrefix("Ideal arrival "), formula)
        XCTAssertTrue(formula.contains("8:15"), formula)
        XCTAssertTrue(formula.hasSuffix("minus 1 hour of travel"), formula)
        XCTAssertFalse(formula.contains("9:00"), "The activity's start plays no part in the formula")

        let shorter = try calculation(arrival: TestFixtures.date(2026, 10, 26, 8, 15), minutes: 45)
        XCTAssertTrue(formatter.departureFormulaText(for: shorter).hasSuffix("minus 45 minutes of travel"))

        let source = formatter.departureSourceText(for: morning)
        XCTAssertTrue(source.hasPrefix("Test commute (simulated, not live traffic), estimated "), source)
        XCTAssertTrue(source.contains("12:00"), "The estimate's own time stamp: \(source)")

        let spoken = formatter.departureAccessibilityLabel(for: morning, at: TestFixtures.date(2026, 10, 26, 6, 0))
        XCTAssertTrue(spoken.hasPrefix("Leave home at "), spoken)
        XCTAssertTrue(spoken.contains("Simulated test data, not live traffic"), spoken)
        XCTAssertFalse(spoken.contains("may miss"), spoken)
    }

    func testPassedLeaveHomeWarnsAboutTheTargetAndKeepsTheCalculatedTime() throws {
        let morning = try calculation(arrival: TestFixtures.date(2026, 10, 26, 8, 15), minutes: 60)
        XCTAssertNil(formatter.departureTimingText(for: morning, at: TestFixtures.date(2026, 10, 26, 7, 0)))
        XCTAssertNil(formatter.departureTimingText(for: morning, at: TestFixtures.date(2026, 10, 26, 7, 15)), "Leaving exactly on time is still on time")

        let late = try XCTUnwrap(formatter.departureTimingText(for: morning, at: TestFixtures.date(2026, 10, 26, 7, 30)))
        XCTAssertTrue(late.contains("7:15"), "The calculated time stays, it is not replaced by now: \(late)")
        XCTAssertFalse(late.contains("7:30"), late)
        XCTAssertTrue(late.contains("may miss"), late)
        XCTAssertTrue(late.contains("8:15"), late)

        let missed = try XCTUnwrap(formatter.departureTimingText(for: morning, at: TestFixtures.date(2026, 10, 26, 8, 20)))
        XCTAssertTrue(missed.contains("arrival target has passed"), missed)
        let spokenLate = formatter.departureAccessibilityLabel(for: morning, at: TestFixtures.date(2026, 10, 26, 7, 30))
        XCTAssertTrue(spokenLate.hasPrefix("Leave home at 7:15"), "VoiceOver keeps the calculated time: \(spokenLate)")
        XCTAssertTrue(spokenLate.contains("may miss"), spokenLate)
        XCTAssertFalse(spokenLate.contains("7:30"), spokenLate)
    }

    func testClockChangeNoteOnlyForTripsAcrossATransition() throws {
        let ordinary = try calculation(arrival: TestFixtures.date(2026, 10, 26, 8, 15), minutes: 60)
        XCTAssertNil(formatter.departureClockChangeNote(for: ordinary))

        // Arrive at the second 1:30 AM (PST) on Sun 2026-11-01; leave at the first 1:30 AM (PDT).
        let fallBack = try calculation(arrival: Date(timeIntervalSince1970: 1_793_525_400), minutes: 60)
        XCTAssertEqual(fallBack.leaveHome, Date(timeIntervalSince1970: 1_793_521_800))
        let note = try XCTUnwrap(formatter.departureClockChangeNote(for: fallBack))
        XCTAssertTrue(note.contains("Clocks change"), note)
    }

    func testEveryStateWithoutATimeExplainsWhy() throws {
        let success = try calculation(arrival: TestFixtures.fridayNoon, minutes: 60)
        XCTAssertNil(formatter.departureMessage(for: .success(success)))
        XCTAssertTrue(formatter.departureMessage(for: .loading)?.hasPrefix("Calculating") ?? false)
        // Refreshing (step 0006) names the old estimate's time and marks the kept time out of date.
        let refreshing = formatter.departureMessage(for: .refreshing(success)) ?? ""
        XCTAssertTrue(refreshing.hasPrefix("Out of date: updating the commute estimate from "), refreshing)
        XCTAssertTrue(refreshing.contains("12:00"), refreshing)
        let staleSpoken = formatter.staleDepartureAccessibilityLabel(for: success)
        XCTAssertTrue(staleSpoken.hasPrefix("Leave home at 11:00"), staleSpoken)
        XCTAssertTrue(staleSpoken.contains("out of date"), staleSpoken)
        // The kept time is still simulated test data while it refreshes; a real estimate is not.
        XCTAssertTrue(staleSpoken.hasSuffix("Simulated test data, not live traffic."), staleSpoken)
        let live = try DepartureCalculation.make(
            idealArrival: TestFixtures.fridayNoon,
            estimate: CommuteEstimate(travelTime: 3_600, sourceLabel: "Team provider", estimatedAt: TestFixtures.fridayNoon, isSimulated: false)
        ).get()
        let liveSpoken = formatter.staleDepartureAccessibilityLabel(for: live)
        XCTAssertTrue(liveSpoken.hasSuffix("Updating the commute estimate."), liveSpoken)
        XCTAssertFalse(liveSpoken.contains("Simulated"), liveSpoken)
        let messages: [(DepartureState, String)] = [
            (.unavailable(.noDestination), "no usable destination"),
            (.unavailable(.noEstimate(message: "No route (test).")), "No route (test)."),
            (.unavailable(.activityEnded), "is over"),
            (.unavailable(.beyondHorizon), "next 7 days"),
            (.unavailable(.unsavedChanges), "Save the change"),
            (.error(.providerFailed), "could not be loaded"),
            (.error(.invalidEstimate(.travelTime(.notPositive))), "zero or negative"),
            (.error(.invalidEstimate(.travelTime(.notFinite))), "not a finite number"),
            (.error(.invalidEstimate(.travelTime(.tooLong))), "longer than 12 hours"),
            (.error(.invalidEstimate(.missingSourceLabel)), "no source label"),
            (.error(.invalidEstimate(.timestamp)), "no valid estimate time")
        ]
        for (state, expected) in messages {
            let message = formatter.departureMessage(for: state) ?? ""
            XCTAssertTrue(message.contains(expected), "\(state): \(message)")
            XCTAssertFalse(message.contains("Leave home at"), "No time is implied for \(state)")
        }
    }

    func testNextTripLineNamesTheDayTheArrivalAndTheStart() throws {
        let activity = TestFixtures.activity(
            title: "Lecture",
            start: TestFixtures.date(2026, 11, 2, 9, 0),
            end: TestFixtures.date(2026, 11, 2, 9, 50),
            arrival: TestFixtures.date(2026, 11, 2, 8, 15)
        )
        let occurrence = try XCTUnwrap(OccurrenceExpander.occurrences(of: [activity], in: TestFixtures.fridayNoon..<TestFixtures.date(2026, 11, 7)).first)
        let line = formatter.nextTripScheduleText(for: occurrence)
        XCTAssertTrue(line.hasPrefix("Monday, November 2: arrive by "), line)
        XCTAssertTrue(line.contains("8:15"), line)
        XCTAssertTrue(line.contains("9:00"), line)
        XCTAssertTrue(line.hasSuffix(" start"), line)
    }
}
