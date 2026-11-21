import XCTest
@testable import WaitItOutUX

/// Step 0005: the validated travel time behind every leave-home time, the Settings test
/// commute field parser, and the tolerant decoding of the stored test commute preference.
final class CommuteDurationTests: XCTestCase {
    private func decodePreferences(_ json: String) throws -> UserPreferences {
        try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
    }

    // MARK: Validation

    func testValidSecondsAreAccepted() throws {
        let hour = try CommuteDuration(seconds: 3_600)
        XCTAssertEqual(hour, .testDefault)
        XCTAssertEqual(hour.seconds, 3_600)
        XCTAssertEqual(CommuteDuration.validated(seconds: 3_600), .success(.testDefault))

        XCTAssertEqual(CommuteDuration.maximumSeconds, 43_200)
        let longest = try CommuteDuration(seconds: CommuteDuration.maximumSeconds)
        XCTAssertEqual(longest.wholeMinutes, CommuteDuration.maximumMinutes)
        XCTAssertEqual(CommuteDuration.validated(seconds: CommuteDuration.maximumSeconds), .success(longest), "Exactly 12 hours is allowed")
    }

    func testZeroAndNegativeSecondsAreRejected() {
        for seconds in [0, -0.0, -60, -CommuteDuration.maximumSeconds] as [TimeInterval] {
            XCTAssertEqual(CommuteDuration.validated(seconds: seconds), .failure(.notPositive), "\(seconds)")
        }
    }

    func testNonfiniteSecondsAreRejected() {
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(CommuteDuration.validated(seconds: seconds), .failure(.notFinite), "\(seconds)")
        }
    }

    func testSecondsLongerThanTwelveHoursAreRejected() {
        for seconds in [CommuteDuration.maximumSeconds + 1, 1e300, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(CommuteDuration.validated(seconds: seconds), .failure(.tooLong), "\(seconds)")
        }
    }

    func testThrowingInitializerThrowsTheIssue() {
        XCTAssertThrowsError(try CommuteDuration(seconds: 0)) { error in
            XCTAssertEqual(error as? CommuteDurationIssue, .notPositive)
        }
        XCTAssertThrowsError(try CommuteDuration(seconds: .nan)) { error in
            XCTAssertEqual(error as? CommuteDurationIssue, .notFinite)
        }
        XCTAssertThrowsError(try CommuteDuration(seconds: CommuteDuration.maximumSeconds + 0.5)) { error in
            XCTAssertEqual(error as? CommuteDurationIssue, .tooLong)
        }
    }

    // MARK: Whole minutes

    func testMinutesFactoryAndTheSixtyMinuteDefault() throws {
        XCTAssertEqual(try CommuteDuration.minutes(60), .testDefault)
        XCTAssertEqual(CommuteDuration.testDefault.seconds, 3_600)
        XCTAssertEqual(CommuteDuration.testDefault.wholeMinutes, 60)
        XCTAssertEqual(CommuteDuration.testDefault.description, "60 min")
        XCTAssertEqual(try CommuteDuration.minutes(1).seconds, 60)
        XCTAssertEqual(try CommuteDuration.minutes(720).seconds, CommuteDuration.maximumSeconds)
        XCTAssertLessThan(try CommuteDuration.minutes(45), .testDefault)
    }

    func testMinutesFactoryRejectsOutOfRangeValues() {
        XCTAssertThrowsError(try CommuteDuration.minutes(0)) { error in
            XCTAssertEqual(error as? CommuteDurationIssue, .notPositive)
        }
        XCTAssertThrowsError(try CommuteDuration.minutes(-5)) { error in
            XCTAssertEqual(error as? CommuteDurationIssue, .notPositive)
        }
        XCTAssertThrowsError(try CommuteDuration.minutes(721)) { error in
            XCTAssertEqual(error as? CommuteDurationIssue, .tooLong)
        }
    }

    // MARK: Settings field

    func testParseMinutesAcceptsWholeMinutesFromOneTo720() throws {
        XCTAssertEqual(CommuteDuration.parseMinutes("60"), .success(.testDefault))
        let fortyFive = try CommuteDuration.minutes(45)
        XCTAssertEqual(CommuteDuration.parseMinutes(" 45 "), .success(fortyFive))
        XCTAssertEqual(CommuteDuration.parseMinutes("\t45\n"), .success(fortyFive))
        let longest = try CommuteDuration.minutes(720)
        XCTAssertEqual(CommuteDuration.parseMinutes("720"), .success(longest))
        XCTAssertEqual(try CommuteDuration.parseMinutes("1").get().seconds, 60)
        XCTAssertEqual(try CommuteDuration.parseMinutes("60").get().wholeMinutes, 60)
    }

    func testParseMinutesRejectsBlankAndNonNumericText() {
        XCTAssertEqual(CommuteDuration.parseMinutes(""), .failure(.empty))
        XCTAssertEqual(CommuteDuration.parseMinutes("   "), .failure(.empty))
        XCTAssertEqual(CommuteDuration.parseMinutes("abc"), .failure(.notANumber))
        XCTAssertEqual(CommuteDuration.parseMinutes("45 min"), .failure(.notANumber))
    }

    func testParseMinutesRejectsFractionsZeroAndNegatives() {
        XCTAssertEqual(CommuteDuration.parseMinutes("12.5"), .failure(.notWholeMinutes))
        for text in ["0", "-5", "-0"] {
            XCTAssertEqual(CommuteDuration.parseMinutes(text), .failure(.notPositive), text)
        }
    }

    func testParseMinutesRejectsTooLongAndNonfiniteText() {
        for text in ["721", "99999999999999999999"] {
            XCTAssertEqual(CommuteDuration.parseMinutes(text), .failure(.tooLong), text)
        }
        // Swift reads "nan" as NaN and "inf" as positive infinity.
        for text in ["nan", "inf", "-inf"] {
            XCTAssertEqual(CommuteDuration.parseMinutes(text), .failure(.notFinite), text)
        }
    }

    func testEveryIssueHasAMessage() {
        let issues: [CommuteDurationIssue] = [.empty, .notANumber, .notWholeMinutes, .notFinite, .notPositive, .tooLong]
        for issue in issues {
            XCTAssertFalse(issue.message.isEmpty, "\(issue)")
        }
        XCTAssertEqual(Set(issues.map(\.message)).count, issues.count, "Each issue explains itself differently")
        XCTAssertTrue(CommuteDurationIssue.tooLong.message.contains("720"))
    }

    // MARK: Codable

    func testDurationRoundTripsThroughJSON() throws {
        let fortyFive = try CommuteDuration.minutes(45)
        let original = [fortyFive, CommuteDuration.testDefault]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode([CommuteDuration].self, from: data), original)
        XCTAssertEqual(try JSONDecoder().decode([CommuteDuration].self, from: Data("[3600]".utf8)), [.testDefault])
    }

    func testDecodingRejectsInvalidDurations() {
        for json in ["[0]", "[-1]", "[1e9]", "[\"sixty\"]"] {
            XCTAssertThrowsError(try JSONDecoder().decode([CommuteDuration].self, from: Data(json.utf8)), json)
        }
    }

    // MARK: Stored preference

    func testPreferencesStartWithTheSixtyMinuteTestCommute() {
        XCTAssertEqual(UserPreferences.default.testCommuteDuration, .testDefault)
        XCTAssertEqual(UserPreferences.default.appearance, .system)
        XCTAssertEqual(UserPreferences().testCommuteDuration, .testDefault)
    }

    func testPreferencesRoundTripTheTestCommuteAndAppearance() throws {
        let fortyFive = try CommuteDuration.minutes(45)
        let original = UserPreferences(appearance: .dark, testCommuteDuration: fortyFive)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertEqual(decoded.testCommuteDuration.wholeMinutes, 45)

        let stored = try decodePreferences(#"{"appearance":"light","testCommuteDuration":2700}"#)
        XCTAssertEqual(stored, UserPreferences(appearance: .light, testCommuteDuration: fortyFive))
    }

    func testPreferencesWithoutAStoredCommuteDecodeSixtyMinutes() throws {
        let decoded = try decodePreferences(#"{"appearance":"dark"}"#)
        XCTAssertEqual(decoded.appearance, .dark)
        XCTAssertEqual(decoded.testCommuteDuration, .testDefault)
    }

    func testPreferencesWithAnInvalidStoredCommuteFallBackToSixtyMinutes() throws {
        let decoded = try decodePreferences(#"{"appearance":"light","testCommuteDuration":0}"#)
        XCTAssertEqual(decoded.appearance, .light)
        XCTAssertEqual(decoded.testCommuteDuration, .testDefault)

        for stored in ["-1", "1e9", "\"sixty\"", "null"] {
            let json = "{\"appearance\":\"light\",\"testCommuteDuration\":\(stored)}"
            XCTAssertEqual(try decodePreferences(json), UserPreferences(appearance: .light, testCommuteDuration: .testDefault), json)
        }
    }

    func testEmptyPreferencesDecodeAsDefaults() throws {
        let decoded = try decodePreferences("{}")
        XCTAssertEqual(decoded.appearance, .system)
        XCTAssertEqual(decoded.testCommuteDuration, .testDefault)
        XCTAssertEqual(decoded, .default)
    }
}
