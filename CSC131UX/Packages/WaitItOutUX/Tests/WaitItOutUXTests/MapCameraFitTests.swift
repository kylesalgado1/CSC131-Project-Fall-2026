import XCTest
@testable import WaitItOutUX

/// Step 0006: the Map camera rules. `MapCameraFit` frames home and campus with padding, takes
/// the short way around the 180th meridian, keeps the latitude span inside the poles, never
/// exceeds a 360-degree longitude span, and returns `nil` when no point is usable. The
/// straight-line distance and midpoint behind the schematic line are checked here too.
final class MapCameraFitTests: XCTestCase {
    private let home = SampleLocation.demoHome.geoCoordinate
    private let campus = SampleLocation.demoCampus.geoCoordinate

    /// Fails unless the region's latitude span lies inside the poles and its longitude span
    /// is valid for MapKit.
    private func assertValidForMapKit(_ region: CoordinateRegion, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(region.center.isValid, "Center \(region.center)", file: file, line: line)
        XCTAssertLessThanOrEqual(region.center.latitude + region.latitudeDelta / 2, 90 + 1e-9, "Top", file: file, line: line)
        XCTAssertGreaterThanOrEqual(region.center.latitude - region.latitudeDelta / 2, -90 - 1e-9, "Bottom", file: file, line: line)
        XCTAssertGreaterThan(region.latitudeDelta, 0, file: file, line: line)
        XCTAssertGreaterThan(region.longitudeDelta, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(region.longitudeDelta, 360, file: file, line: line)
    }

    // MARK: Fitting

    func testSamplePairIsFramedWithPadding() throws {
        let region = try XCTUnwrap(MapCameraFit.region(fitting: [home, campus]))
        XCTAssertEqual(region.center.latitude, 38.4849, accuracy: 1e-6)
        XCTAssertEqual(region.center.longitude, -121.39765, accuracy: 1e-6)
        XCTAssertEqual(region.latitudeDelta, 0.24352, accuracy: 1e-6, "0.1522 degrees of latitude times 1.6")
        XCTAssertEqual(region.longitudeDelta, 0.08336, accuracy: 1e-6, "0.0521 degrees of longitude times 1.6")
        XCTAssertTrue(region.contains(home))
        XCTAssertTrue(region.contains(campus))
        assertValidForMapKit(region)

        let reversed = try XCTUnwrap(MapCameraFit.region(fitting: [campus, home]))
        XCTAssertEqual(reversed.center.latitude, region.center.latitude, accuracy: 1e-9, "Order does not matter")
        XCTAssertEqual(reversed.center.longitude, region.center.longitude, accuracy: 1e-9)
        XCTAssertEqual(reversed.latitudeDelta, region.latitudeDelta, accuracy: 1e-9)
        XCTAssertEqual(reversed.longitudeDelta, region.longitudeDelta, accuracy: 1e-9)
    }

    func testIdenticalPointsUseTheMinimumSpanCenteredOnThePoint() throws {
        let point = GeoCoordinate(latitude: 38.5, longitude: -121.4)
        let region = try XCTUnwrap(MapCameraFit.region(fitting: [point, point]))
        XCTAssertEqual(region.center.latitude, 38.5, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, -121.4, accuracy: 1e-9)
        XCTAssertEqual(region.latitudeDelta, MapCameraFit.minimumSpan, accuracy: 1e-9)
        XCTAssertEqual(region.longitudeDelta, MapCameraFit.minimumSpan, accuracy: 1e-9)
        XCTAssertTrue(region.contains(point))
        assertValidForMapKit(region)
    }

    func testOnePointUsesTheMinimumSpan() throws {
        let region = try XCTUnwrap(MapCameraFit.region(fitting: [campus]))
        XCTAssertEqual(region.center.latitude, campus.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, campus.longitude, accuracy: 1e-9)
        XCTAssertEqual(region.latitudeDelta, 0.02, accuracy: 1e-9)
        XCTAssertEqual(region.longitudeDelta, 0.02, accuracy: 1e-9)
        XCTAssertTrue(region.contains(campus))
    }

    func testNoUsablePointGivesNoRegion() {
        XCTAssertNil(MapCameraFit.region(fitting: []))
        let unusable = [
            GeoCoordinate(latitude: .nan, longitude: 0),
            GeoCoordinate(latitude: 91, longitude: 0),
            GeoCoordinate(latitude: 0, longitude: 181),
            GeoCoordinate(latitude: 0, longitude: -.infinity)
        ]
        XCTAssertNil(MapCameraFit.region(fitting: unusable))
    }

    func testUnusablePointsAreIgnored() throws {
        let clean = try XCTUnwrap(MapCameraFit.region(fitting: [home, campus]))
        let mixed = [home, GeoCoordinate(latitude: .nan, longitude: 0), campus, GeoCoordinate(latitude: 95, longitude: -121)]
        let filtered = try XCTUnwrap(MapCameraFit.region(fitting: mixed))
        XCTAssertEqual(filtered, clean)

        let single = try XCTUnwrap(MapCameraFit.region(fitting: [GeoCoordinate(latitude: 0, longitude: 200), home]))
        XCTAssertEqual(single.center.latitude, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(single.center.longitude, home.longitude, accuracy: 1e-9)
        XCTAssertEqual(single.longitudeDelta, MapCameraFit.minimumSpan, accuracy: 1e-9)
    }

    func testPointsEitherSideOfTheAntimeridianTakeTheShortWay() throws {
        let east = GeoCoordinate(latitude: 10, longitude: 179.9)
        let west = GeoCoordinate(latitude: 10, longitude: -179.9)
        let region = try XCTUnwrap(MapCameraFit.region(fitting: [east, west]))
        XCTAssertEqual(region.longitudeDelta, 0.2 * MapCameraFit.paddingFactor, accuracy: 1e-6, "A fraction of a degree, not the whole globe")
        XCTAssertEqual(abs(region.center.longitude), 180, accuracy: 1e-6)
        XCTAssertEqual(region.center.latitude, 10, accuracy: 1e-9)
        XCTAssertTrue(region.contains(east))
        XCTAssertTrue(region.contains(west))
        XCTAssertFalse(region.contains(GeoCoordinate(latitude: 10, longitude: 0)), "The far side of the globe is outside")
        assertValidForMapKit(region)
    }

    func testRegionsNearThePolesStayInsideThem() throws {
        let near = try XCTUnwrap(MapCameraFit.region(fitting: [
            GeoCoordinate(latitude: 89.9, longitude: 0),
            GeoCoordinate(latitude: 89.95, longitude: 10)
        ]))
        assertValidForMapKit(near)
        XCTAssertTrue(near.contains(GeoCoordinate(latitude: 89.9, longitude: 0)))
        XCTAssertTrue(near.contains(GeoCoordinate(latitude: 89.95, longitude: 10)))

        // The padded box would pass the pole, so it is shifted south and keeps its span.
        let clamped = try XCTUnwrap(MapCameraFit.region(fitting: [
            GeoCoordinate(latitude: 89.9, longitude: 0),
            GeoCoordinate(latitude: 89.99, longitude: 10)
        ]))
        assertValidForMapKit(clamped)
        XCTAssertEqual(clamped.center.latitude + clamped.latitudeDelta / 2, 90, accuracy: 1e-9, "Top at the pole")
        XCTAssertEqual(clamped.latitudeDelta, 0.09 * MapCameraFit.paddingFactor, accuracy: 1e-6)
        XCTAssertTrue(clamped.contains(GeoCoordinate(latitude: 89.99, longitude: 10)))
        XCTAssertTrue(clamped.contains(GeoCoordinate(latitude: 89.9, longitude: 0)))

        let northPole = try XCTUnwrap(MapCameraFit.region(fitting: [GeoCoordinate(latitude: 90, longitude: 0)]))
        assertValidForMapKit(northPole)
        XCTAssertTrue(northPole.contains(GeoCoordinate(latitude: 90, longitude: 0)))

        let southPole = try XCTUnwrap(MapCameraFit.region(fitting: [GeoCoordinate(latitude: -90, longitude: 0)]))
        assertValidForMapKit(southPole)
        XCTAssertEqual(southPole.center.latitude - southPole.latitudeDelta / 2, -90, accuracy: 1e-9, "Bottom at the pole")
        XCTAssertTrue(southPole.contains(GeoCoordinate(latitude: -90, longitude: 0)))

        // Pole to pole: the padded span is cut to the whole 180 degrees of latitude.
        let tall = try XCTUnwrap(MapCameraFit.region(fitting: [
            GeoCoordinate(latitude: -89, longitude: 0),
            GeoCoordinate(latitude: 89, longitude: 0)
        ]))
        assertValidForMapKit(tall)
        XCTAssertEqual(tall.latitudeDelta, 180, accuracy: 1e-9)
        XCTAssertEqual(tall.center.latitude, 0, accuracy: 1e-9)
    }

    func testFarApartPointsNeverExceedTheWholeGlobe() throws {
        let spread = [
            GeoCoordinate(latitude: 0, longitude: -170),
            GeoCoordinate(latitude: 0, longitude: -50),
            GeoCoordinate(latitude: 0, longitude: 70)
        ]
        let region = try XCTUnwrap(MapCameraFit.region(fitting: spread))
        XCTAssertEqual(region.longitudeDelta, 360, "240 degrees times 1.6 is capped at 360")
        assertValidForMapKit(region)
        for point in spread {
            XCTAssertTrue(region.contains(point), "\(point)")
        }

        let opposite = try XCTUnwrap(MapCameraFit.region(fitting: [
            GeoCoordinate(latitude: 40, longitude: -120),
            GeoCoordinate(latitude: -35, longitude: 150)
        ]))
        assertValidForMapKit(opposite)
        XCTAssertTrue(opposite.contains(GeoCoordinate(latitude: 40, longitude: -120)))
        XCTAssertTrue(opposite.contains(GeoCoordinate(latitude: -35, longitude: 150)))
    }

    // MARK: Containment

    func testRegionDoesNotContainFarOrUnusablePoints() throws {
        let region = try XCTUnwrap(MapCameraFit.region(fitting: [home, campus]))
        XCTAssertFalse(region.contains(GeoCoordinate(latitude: 0, longitude: 0)))
        XCTAssertFalse(region.contains(GeoCoordinate(latitude: 38.4849, longitude: -100)), "Too far east")
        XCTAssertFalse(region.contains(GeoCoordinate(latitude: 60, longitude: -121.4)), "Too far north")
        XCTAssertFalse(region.contains(GeoCoordinate(latitude: .nan, longitude: -121.4)))
        XCTAssertFalse(region.contains(GeoCoordinate(latitude: 38.5, longitude: 190)))

        // A region centered on the 180th meridian holds points just across it.
        let dateline = CoordinateRegion(center: GeoCoordinate(latitude: 0, longitude: 180), latitudeDelta: 10, longitudeDelta: 10)
        XCTAssertTrue(dateline.contains(GeoCoordinate(latitude: 0, longitude: -176)))
        XCTAssertTrue(dateline.contains(GeoCoordinate(latitude: 4, longitude: 176)))
        XCTAssertFalse(dateline.contains(GeoCoordinate(latitude: 0, longitude: -170)))
        XCTAssertFalse(dateline.contains(GeoCoordinate(latitude: 6, longitude: 180)))
    }

    // MARK: Distance and midpoint

    func testStraightLineDistanceBetweenTheSamplePlaces() {
        XCTAssertEqual(home.distance(to: campus), 17_521, accuracy: 5)
        XCTAssertEqual(campus.distance(to: home), home.distance(to: campus), accuracy: 1e-6, "Symmetric")
        XCTAssertEqual(home.distance(to: home), 0, accuracy: 1e-9)

        let east = GeoCoordinate(latitude: 0, longitude: 179.95)
        let west = GeoCoordinate(latitude: 0, longitude: -179.95)
        let acrossDateline = east.distance(to: west)
        XCTAssertLessThan(acrossDateline, 12_000, "0.1 degrees at the equator, about 11 km, the short way")
        XCTAssertGreaterThan(acrossDateline, 10_000)
    }

    func testMidpointTakesTheShortWay() {
        let middle = home.midpoint(to: campus)
        XCTAssertEqual(middle.latitude, 38.4849, accuracy: 1e-9)
        XCTAssertEqual(middle.longitude, -121.39765, accuracy: 1e-9)

        let dateline = GeoCoordinate(latitude: 10, longitude: 179.9).midpoint(to: GeoCoordinate(latitude: 10, longitude: -179.9))
        XCTAssertEqual(dateline.latitude, 10, accuracy: 1e-9)
        XCTAssertEqual(abs(dateline.longitude), 180, accuracy: 1e-6, "Near the 180th meridian, not near 0")
        XCTAssertTrue(dateline.isValid)
    }
}
