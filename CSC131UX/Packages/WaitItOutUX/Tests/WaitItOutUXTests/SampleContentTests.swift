import XCTest
@testable import WaitItOutUX

final class SampleContentTests: XCTestCase {
    func testDemoCampusIsValidAndLabeledAsDemo() {
        let campus = SampleLocation.demoCampus
        XCTAssertTrue(campus.hasValidCoordinate)
        XCTAssertTrue(campus.name.localizedCaseInsensitiveContains("sample"))
        XCTAssertTrue(campus.provenance.localizedCaseInsensitiveContains("demo"))
        XCTAssertEqual(campus.coordinate.latitude, campus.latitude)
        XCTAssertEqual(campus.coordinate.longitude, campus.longitude)
        XCTAssertEqual(campus.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertTrue(campus.hasKnownTimeZone)
        XCTAssertEqual(campus.timeZone.identifier, "America/Los_Angeles")
    }

    /// Step 0006: the labeled sample home, and the sample pair Settings restores.
    func testDemoHomeIsValidAndLabeledAsDemo() throws {
        let home = SampleLocation.demoHome
        XCTAssertTrue(home.hasValidCoordinate)
        XCTAssertTrue(home.name.contains("Sample"), home.name)
        XCTAssertTrue(home.provenance.contains("Demo"), home.provenance)
        XCTAssertEqual(home.name, "Sample home")
        XCTAssertEqual(home.latitude, 38.4088)
        XCTAssertEqual(home.longitude, -121.3716)
        XCTAssertEqual(home.timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertNotEqual(home.destinationID, SampleLocation.demoCampus.destinationID, "Home is never the campus destination")
        XCTAssertNotEqual(home.geoCoordinate, SampleLocation.demoCampus.geoCoordinate)

        let sample = CommutePlaces.sample
        XCTAssertEqual(sample.home.name, home.name)
        XCTAssertEqual(sample.home.coordinate, home.geoCoordinate)
        XCTAssertEqual(sample.campus.name, SampleLocation.demoCampus.name)
        XCTAssertEqual(sample.campus.coordinate, SampleLocation.demoCampus.geoCoordinate)
        XCTAssertEqual(CommutePlace(sample: SampleLocation.demoHome), sample.home)
        XCTAssertEqual(CommutePlace(sample: SampleLocation.demoCampus), sample.campus)
        XCTAssertEqual(CommutePlaces.sample(home: SampleLocation.demoHome, campus: SampleLocation.demoCampus), sample)
        XCTAssertEqual(sample[.home], sample.home)
        XCTAssertEqual(sample[.campus], sample.campus)
        XCTAssertEqual(UserPreferences.default.places, sample, "Settings start with the labeled sample pair")
    }

    func testDemoCampusExposesADestinationForActivities() {
        let campus = SampleLocation.demoCampus
        let destination = campus.destination
        XCTAssertEqual(destination.id, DestinationID("demo-campus"))
        XCTAssertEqual(destination.name, campus.name)
        XCTAssertEqual(destination.coordinate, campus.geoCoordinate)
        XCTAssertTrue(destination.coordinate.isValid)
        XCTAssertEqual(destination.coordinate.locationCoordinate.latitude, campus.latitude)
    }

    func testUnknownTimeZoneFallsBackInsteadOfCrashing() {
        let odd = SampleLocation(name: "Odd", provenance: "Test", latitude: 0, longitude: 0, timeZoneIdentifier: "Nowhere/Here", destinationID: DestinationID("odd"))
        XCTAssertFalse(odd.hasKnownTimeZone)
        XCTAssertEqual(odd.timeZone, .autoupdatingCurrent)
    }

    func testCoordinateValidationRejectsInvalidValues() {
        XCTAssertFalse(SampleLocation.isValidCoordinate(latitude: .nan, longitude: 0))
        XCTAssertFalse(SampleLocation.isValidCoordinate(latitude: 0, longitude: .infinity))
        XCTAssertFalse(SampleLocation.isValidCoordinate(latitude: 90.0001, longitude: 0))
        XCTAssertFalse(SampleLocation.isValidCoordinate(latitude: 0, longitude: -180.5))
        XCTAssertTrue(SampleLocation.isValidCoordinate(latitude: -90, longitude: 180))
        XCTAssertTrue(SampleLocation.isValidCoordinate(latitude: 0, longitude: 0))
        XCTAssertFalse(GeoCoordinate(latitude: -90.5, longitude: 0).isValid)
        XCTAssertTrue(GeoCoordinate(latitude: 38.5610, longitude: -121.4237).isValid)
    }

    func testDestinationAndIdRoundTripThroughCodable() throws {
        let destination = SampleLocation.demoCampus.destination
        let data = try JSONEncoder().encode(destination)
        XCTAssertEqual(try JSONDecoder().decode(Destination.self, from: data), destination)
        let idData = try JSONEncoder().encode(DestinationID("demo-campus"))
        XCTAssertEqual(String(decoding: idData, as: UTF8.self), "\"demo-campus\"")
        XCTAssertEqual(try JSONDecoder().decode(DestinationID.self, from: idData), DestinationID("demo-campus"))
    }

    func testOccurrenceIDRoundTripsThroughTextAndCodable() throws {
        let id = OccurrenceID(activityID: SampleActivities.morningClassID, date: LocalDate(dayNumber: 20_756))
        XCTAssertEqual(id.rawValue, "5A170002-0000-4000-8000-0000000000A1@2026-10-30")
        XCTAssertEqual(id.description, id.rawValue)
        XCTAssertEqual(OccurrenceID(rawValue: id.rawValue), id)
        XCTAssertNil(OccurrenceID(rawValue: "not-an-id"))
        XCTAssertNil(OccurrenceID(rawValue: "\(UUID().uuidString)@2026-02-30"))
        XCTAssertNil(OccurrenceID(rawValue: "nope@2026-10-30"))
        let data = try JSONEncoder().encode([id])
        XCTAssertEqual(try JSONDecoder().decode([OccurrenceID].self, from: data), [id])
        XCTAssertThrowsError(try JSONDecoder().decode([OccurrenceID].self, from: Data("[\"bad\"]".utf8)))
    }

    func testPrototypeInfoReadsBundleKeysWithFallbacks() {
        let full = PrototypeInfo(infoDictionary: [
            "CFBundleDisplayName": "WAIT IT OUT",
            "CFBundleName": "WaitItOutUXPrototype",
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "34"
        ])
        XCTAssertEqual(full.appName, "WAIT IT OUT")
        XCTAssertEqual(full.version, "1.2")
        XCTAssertEqual(full.build, "34")

        let nameOnly = PrototypeInfo(infoDictionary: ["CFBundleName": "Host", "CFBundleShortVersionString": ""])
        XCTAssertEqual(nameOnly.appName, "Host")
        XCTAssertEqual(nameOnly.version, "unknown")
        XCTAssertEqual(nameOnly.build, "unknown")

        let empty = PrototypeInfo(infoDictionary: nil)
        XCTAssertEqual(empty.appName, "WAIT IT OUT UX Prototype")
        XCTAssertEqual(empty.packageName, "WaitItOutUX")
        XCTAssertTrue(empty.dataDisclosure.localizedCaseInsensitiveContains("demo"))
        XCTAssertTrue(empty.stepDescription.contains("step 8 of 8"))
    }

    func testTabMetadata() {
        XCTAssertEqual(PrototypeTab.displayOrder.map(\.title), ["Map", "Calendar", "Settings"])
        XCTAssertEqual(Set(PrototypeTab.displayOrder), Set(PrototypeTab.allCases))
        XCTAssertEqual(PrototypeTab.displayOrder.last, .settings, "Settings must be the rightmost tab")
    }
}
