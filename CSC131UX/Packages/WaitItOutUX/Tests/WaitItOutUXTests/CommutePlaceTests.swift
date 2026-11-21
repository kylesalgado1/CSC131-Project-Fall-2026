import XCTest
@testable import WaitItOutUX

/// Step 0006: home and campus as typed in Settings. `PlaceInput` parses strict decimal degrees
/// and reports every issue at once in field order; `CommutePlace` is valid by construction,
/// including when decoded; `UserPreferences` decodes tolerantly, so one unusable stored value
/// falls back to its sample instead of failing the whole settings load.
final class CommutePlaceTests: XCTestCase {
    /// The sample campus as typed, unless a field is overridden.
    private func input(name: String = "Sample campus", latitude: String = "38.5610", longitude: String = "-121.4237") -> PlaceInput {
        PlaceInput(name: name, latitude: latitude, longitude: longitude)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func place(_ name: String, _ latitude: Double, _ longitude: Double) throws -> CommutePlace {
        try CommutePlace(name: name, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude))
    }

    // MARK: PlaceInput

    func testValidSampleInputGivesThePlace() throws {
        let valid = input()
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.issues, [])
        let parsed = try valid.place().get()
        XCTAssertEqual(parsed.name, "Sample campus")
        XCTAssertEqual(parsed.coordinate, GeoCoordinate(latitude: 38.5610, longitude: -121.4237))
        XCTAssertEqual(parsed, CommutePlaces.sample.campus)

        let home = PlaceInput(name: "Sample home", latitude: "38.4088", longitude: "-121.3716")
        XCTAssertEqual(try home.place().get(), CommutePlaces.sample.home)
    }

    func testEmptyNameIsReported() {
        XCTAssertEqual(input(name: "").issues, [.emptyName])
        XCTAssertEqual(input(name: "   ").issues, [.emptyName])
        XCTAssertEqual(input(name: " \n\t ").issues, [.emptyName])
        XCTAssertFalse(input(name: "").isValid)
    }

    func testEmptyCoordinatesAreReported() {
        XCTAssertEqual(input(latitude: "").issues, [.emptyLatitude])
        XCTAssertEqual(input(latitude: "   ").issues, [.emptyLatitude])
        XCTAssertEqual(input(longitude: "").issues, [.emptyLongitude])
        XCTAssertEqual(input(longitude: " \t").issues, [.emptyLongitude])
    }

    func testTextThatIsNotPlainDecimalDegreesIsRejected() {
        let rejected = ["abc", "1e5", "0x10", "nan", "inf", "38.5\u{00B0}", "38.5N", "1.2.3", "38,56,10", "- 38.5", "--38", ".", "-"]
        for text in rejected {
            XCTAssertEqual(input(latitude: text).issues, [.latitudeNotANumber], "Latitude \"\(text)\"")
            XCTAssertEqual(input(longitude: text).issues, [.longitudeNotANumber], "Longitude \"\(text)\"")
            XCTAssertNil(PlaceInput.parseDegrees(text), "\"\(text)\"")
        }
    }

    func testOutOfRangeCoordinatesAreRejected() {
        XCTAssertEqual(input(latitude: "90.0001").issues, [.latitudeOutOfRange])
        XCTAssertEqual(input(latitude: "-90.5").issues, [.latitudeOutOfRange])
        XCTAssertEqual(input(longitude: "-180.5").issues, [.longitudeOutOfRange])
        XCTAssertEqual(input(longitude: "180.0001").issues, [.longitudeOutOfRange])
    }

    func testCoordinatesAtTheLimitsAreAccepted() throws {
        let corner = try PlaceInput(name: "Corner", latitude: "-90", longitude: "180").place().get()
        XCTAssertEqual(corner.coordinate, GeoCoordinate(latitude: -90, longitude: 180))
        let otherCorner = try PlaceInput(name: "Other corner", latitude: "90", longitude: "-180").place().get()
        XCTAssertEqual(otherCorner.coordinate, GeoCoordinate(latitude: 90, longitude: -180))
    }

    func testDecimalCommaTypographicMinusAndSurroundingSpacesAreAccepted() throws {
        let typed = PlaceInput(name: "  Sample campus ", latitude: " 38,5610 ", longitude: "\u{2212}121.4237")
        XCTAssertEqual(typed.issues, [])
        let parsed = try typed.place().get()
        XCTAssertEqual(parsed, CommutePlaces.sample.campus)
        XCTAssertEqual(parsed.name, "Sample campus", "The name is trimmed")

        XCTAssertEqual(PlaceInput.parseDegrees("38,5610"), 38.5610)
        XCTAssertEqual(PlaceInput.parseDegrees("\u{2212}121.4237"), -121.4237)
        XCTAssertEqual(PlaceInput.parseDegrees("\u{2212}121,4237"), -121.4237)
        XCTAssertEqual(PlaceInput.parseDegrees(" +38.5 "), 38.5)
        XCTAssertEqual(PlaceInput.parseDegrees("-0.25"), -0.25)
        XCTAssertEqual(PlaceInput.parseDegrees("12"), 12)
    }

    func testEveryIssueIsReportedAtOnceInFieldOrder() {
        XCTAssertEqual(
            PlaceInput(name: "", latitude: "", longitude: "").issues,
            [.emptyName, .emptyLatitude, .emptyLongitude]
        )
        XCTAssertEqual(
            PlaceInput(name: " ", latitude: "abc", longitude: "200").issues,
            [.emptyName, .latitudeNotANumber, .longitudeOutOfRange]
        )
        XCTAssertEqual(
            PlaceInput(name: "", latitude: "91", longitude: "x").issues,
            [.emptyName, .latitudeOutOfRange, .longitudeNotANumber]
        )
        let failure = PlaceInput(name: "Home", latitude: "nan", longitude: "").place()
        XCTAssertEqual(failure, .failure(PlaceValidationError(issues: [.latitudeNotANumber, .emptyLongitude])))
    }

    func testIssuesNameTheirFieldAndExplainThemselves() {
        let all: [PlaceIssue] = [
            .emptyName,
            .emptyLatitude,
            .latitudeNotANumber,
            .latitudeOutOfRange,
            .emptyLongitude,
            .longitudeNotANumber,
            .longitudeOutOfRange
        ]
        XCTAssertEqual(all.map(\.field), [.name, .latitude, .latitude, .latitude, .longitude, .longitude, .longitude])
        for issue in all {
            XCTAssertFalse(issue.message.isEmpty, "\(issue)")
        }
        XCTAssertEqual(Set(all.map(\.message)).count, all.count, "Every issue has its own message")
        XCTAssertEqual(PlaceRole.allCases, [.home, .campus])
        XCTAssertEqual(PlaceRole.allCases.map(\.title), ["Home", "Campus"])
    }

    // MARK: CommutePlace

    func testCommutePlaceRejectsUnusableValuesWithEveryIssue() throws {
        XCTAssertThrowsError(try place("  ", 38.5, -121.4)) { error in
            XCTAssertEqual(error as? PlaceValidationError, PlaceValidationError(issues: [.emptyName]))
        }
        XCTAssertThrowsError(try place("Home", .nan, -121.4)) { error in
            XCTAssertEqual(error as? PlaceValidationError, PlaceValidationError(issues: [.latitudeNotANumber]))
        }
        XCTAssertThrowsError(try place("Home", 38.5, .infinity)) { error in
            XCTAssertEqual(error as? PlaceValidationError, PlaceValidationError(issues: [.longitudeNotANumber]))
        }
        XCTAssertThrowsError(try place("Home", 90.0001, -121.4)) { error in
            XCTAssertEqual(error as? PlaceValidationError, PlaceValidationError(issues: [.latitudeOutOfRange]))
        }
        XCTAssertThrowsError(try place("", 91, -181)) { error in
            XCTAssertEqual(
                error as? PlaceValidationError,
                PlaceValidationError(issues: [.emptyName, .latitudeOutOfRange, .longitudeOutOfRange])
            )
        }
        XCTAssertEqual(CommutePlace.issues(name: "Edge", coordinate: GeoCoordinate(latitude: -90, longitude: 180)), [])
        XCTAssertNoThrow(try place("Edge", 90, -180))
    }

    func testNameIsTrimmed() throws {
        let trimmed = try place("  My home \n", 38.4088, -121.3716)
        XCTAssertEqual(trimmed.name, "My home")
        let typed = try PlaceInput(name: "\tMy home ", latitude: "38.4088", longitude: "-121.3716").place().get()
        XCTAssertEqual(typed, trimmed)
    }

    func testCoordinateTextUsesFourDecimalsAndAPeriod() throws {
        XCTAssertEqual(CommutePlaces.sample.home.coordinateText, "38.4088, -121.3716")
        let campusText = CommutePlaces.sample.campus.coordinateText
        XCTAssertTrue(campusText.hasPrefix("38.561"), campusText)
        XCTAssertTrue(campusText.hasSuffix(", -121.4237"), campusText)
        XCTAssertEqual(try place("Rounded", 38.123456, -121.987654).coordinateText, "38.1235, -121.9877")
        XCTAssertEqual(try place("Origin", 0, 0).coordinateText, "0.0, 0.0")
    }

    func testFormatDegreesTrimsTrailingZerosAndNeverShowsNegativeZero() {
        XCTAssertEqual(PlaceInput.formatDegrees(38.561, fractionDigits: 6), "38.561")
        XCTAssertEqual(PlaceInput.formatDegrees(-121.4237, fractionDigits: 6), "-121.4237")
        XCTAssertEqual(PlaceInput.formatDegrees(-0.0, fractionDigits: 4), "0.0")
        XCTAssertEqual(PlaceInput.formatDegrees(-0.00001, fractionDigits: 4), "0.0", "Rounds to zero without a minus sign")
        XCTAssertEqual(PlaceInput.formatDegrees(0, fractionDigits: 4), "0.0")
        XCTAssertEqual(PlaceInput.formatDegrees(180, fractionDigits: 6), "180.0")
        XCTAssertEqual(PlaceInput.formatDegrees(1.24, fractionDigits: 0), "1.2", "At least one decimal")
        XCTAssertEqual(PlaceInput.formatDegrees(.nan, fractionDigits: 4), "")
        XCTAssertEqual(PlaceInput.formatDegrees(.infinity, fractionDigits: 4), "")
    }

    func testPlaceInputForAPlaceRoundTrips() throws {
        let home = CommutePlaces.sample.home
        let fields = PlaceInput(place: home)
        XCTAssertEqual(fields, PlaceInput(name: "Sample home", latitude: "38.4088", longitude: "-121.3716"))
        XCTAssertEqual(try fields.place().get(), home)

        let campus = CommutePlaces.sample.campus
        XCTAssertEqual(PlaceInput(place: campus), PlaceInput(name: "Sample campus", latitude: "38.561", longitude: "-121.4237"))
        XCTAssertEqual(try PlaceInput(place: campus).place().get(), campus)

        let precise = try place("Precise", 38.123456, -121.654321)
        XCTAssertEqual(PlaceInput(place: precise).latitude, "38.123456")
        XCTAssertEqual(PlaceInput(place: precise).longitude, "-121.654321")
        XCTAssertEqual(try PlaceInput(place: precise).place().get(), precise)
    }

    func testCommutePlacesSubscriptReadsAndWritesEachRole() throws {
        var places = CommutePlaces.sample
        let custom = try place("My home", 38.6, -121.5)
        places[.home] = custom
        XCTAssertEqual(places.home, custom)
        XCTAssertEqual(places[.home], custom)
        XCTAssertEqual(places.campus, CommutePlaces.sample.campus, "The other place is untouched")
        XCTAssertNotEqual(places, CommutePlaces.sample)
    }

    // MARK: Codable

    func testCommutePlaceRoundTripsThroughCodable() throws {
        let original = try place("My campus", 38.5, -121.75)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(CommutePlace.self, from: data), original)

        let pair = CommutePlaces(home: try place("My home", 38.6, -121.5), campus: original)
        let pairData = try JSONEncoder().encode(pair)
        XCTAssertEqual(try JSONDecoder().decode(CommutePlaces.self, from: pairData), pair)

        let stored = try decode(CommutePlace.self, from: #"{"name":"  Spaced home ","coordinate":{"latitude":38.4,"longitude":-121.3}}"#)
        XCTAssertEqual(stored.name, "Spaced home", "Decoding trims the name too")
    }

    func testDecodingAnUnusablePlaceFails() {
        let outOfRange = #"{"name":"Far north","coordinate":{"latitude":91,"longitude":0}}"#
        XCTAssertThrowsError(try decode(CommutePlace.self, from: outOfRange))
        let farEast = #"{"name":"Far east","coordinate":{"latitude":0,"longitude":180.5}}"#
        XCTAssertThrowsError(try decode(CommutePlace.self, from: farEast))
        let blank = #"{"name":"   ","coordinate":{"latitude":38.5,"longitude":-121.4}}"#
        XCTAssertThrowsError(try decode(CommutePlace.self, from: blank))
        let missingName = #"{"coordinate":{"latitude":38.5,"longitude":-121.4}}"#
        XCTAssertThrowsError(try decode(CommutePlace.self, from: missingName))
    }

    // MARK: Stored preferences

    func testEmptyStoredPreferencesDecodeAsDefaults() throws {
        let decoded = try decode(UserPreferences.self, from: "{}")
        XCTAssertEqual(decoded, UserPreferences())
        XCTAssertEqual(decoded.appearance, .system)
        XCTAssertEqual(decoded.testCommuteDuration, .testDefault)
        XCTAssertEqual(decoded.testCommuteScenario, .normal)
        XCTAssertEqual(decoded.places, CommutePlaces.sample)
    }

    func testUnknownStoredScenarioFallsBackToNormal() throws {
        let decoded = try decode(UserPreferences.self, from: #"{"appearance":"dark","testCommuteScenario":"storm"}"#)
        XCTAssertEqual(decoded.testCommuteScenario, .normal)
        XCTAssertEqual(decoded.appearance, .dark, "The rest of the settings still load")

        let slow = try decode(UserPreferences.self, from: #"{"testCommuteScenario":"slow"}"#)
        XCTAssertEqual(slow.testCommuteScenario, .slow)
        let numeric = try decode(UserPreferences.self, from: #"{"testCommuteScenario":3}"#)
        XCTAssertEqual(numeric.testCommuteScenario, .normal)
    }

    func testUnusableStoredHomeFallsBackToTheSampleAndKeepsTheCampus() throws {
        let json = """
        {"testCommuteDuration":2700,"places":{"home":{"name":"Bad home","coordinate":{"latitude":123,"longitude":-121.3}},\
        "campus":{"name":"My campus","coordinate":{"latitude":38.6,"longitude":-121.5}}}}
        """
        let decoded = try decode(UserPreferences.self, from: json)
        XCTAssertEqual(decoded.places.home, CommutePlaces.sample.home)
        XCTAssertEqual(decoded.places.campus, try place("My campus", 38.6, -121.5))
        XCTAssertEqual(decoded.testCommuteDuration, try CommuteDuration.minutes(45), "The rest of the settings still load")

        let missingCampus = try decode(UserPreferences.self, from: #"{"places":{"home":{"name":"My home","coordinate":{"latitude":38.6,"longitude":-121.5}}}}"#)
        XCTAssertEqual(missingCampus.places.home, try place("My home", 38.6, -121.5))
        XCTAssertEqual(missingCampus.places.campus, CommutePlaces.sample.campus)

        let garbage = try decode(UserPreferences.self, from: #"{"appearance":"light","places":"nowhere"}"#)
        XCTAssertEqual(garbage.places, CommutePlaces.sample)
        XCTAssertEqual(garbage.appearance, .light)
    }

    func testPreferencesRoundTripTheScenarioAndCustomPlaces() throws {
        let custom = CommutePlaces(home: try place("My home", 38.6, -121.5), campus: try place("My campus", 38.55, -121.42))
        let original = UserPreferences(
            appearance: .dark,
            testCommuteDuration: try CommuteDuration.minutes(45),
            testCommuteScenario: .slow,
            places: custom
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.testCommuteScenario, .slow)
        XCTAssertEqual(decoded.places, custom)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""testCommuteScenario":"slow""#), text)
    }
}
