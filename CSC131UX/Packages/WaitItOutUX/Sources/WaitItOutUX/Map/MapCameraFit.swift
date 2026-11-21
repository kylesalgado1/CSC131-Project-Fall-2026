import Foundation

/// A map region in degrees, independent of MapKit so the camera rules stay pure and testable.
/// `MapScreen` converts it to `MKCoordinateRegion`. Every value `MapCameraFit` returns is
/// valid for MapKit: the center is in range, the latitude span stays inside -90...90, and the
/// longitude span is at most 360 degrees.
public struct CoordinateRegion: Equatable, Sendable {
    public let center: GeoCoordinate
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(center: GeoCoordinate, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// True when `point` lies inside the region, including regions that cross the 180th meridian.
    public func contains(_ point: GeoCoordinate) -> Bool {
        guard point.isValid, center.isValid else { return false }
        let halfLatitude = latitudeDelta / 2
        guard point.latitude >= center.latitude - halfLatitude, point.latitude <= center.latitude + halfLatitude else {
            return false
        }
        guard longitudeDelta < 360 else { return true }
        return abs(MapCameraFit.longitudeDifference(from: center.longitude, to: point.longitude)) <= longitudeDelta / 2
    }
}

/// Camera rules for the Map tab (step 0006). Pure: the view passes the configured places and
/// applies the returned region.
///
/// - Two or more points: the smallest box that holds them, taking the short way around the
///   180th meridian, enlarged by `paddingFactor` so markers and their titles stay clear of the
///   edges, and never smaller than `minimumSpan`.
/// - One point (identical home and campus, for example): centered on it with `minimumSpan`.
/// - No valid point: `nil`, and the caller keeps its fallback.
public enum MapCameraFit {
    /// Smallest span in degrees, about 2.2 km of latitude, so nearby pins are not over-zoomed.
    public static let minimumSpan: Double = 0.02
    /// How much larger than the bounding box the region is, so both markers sit inside it.
    public static let paddingFactor: Double = 1.6

    public static func region(fitting points: [GeoCoordinate]) -> CoordinateRegion? {
        let valid = points.filter(\.isValid)
        guard let first = valid.first else { return nil }

        // Latitude: pad the box, then keep it inside the poles.
        let latitudes = valid.map(\.latitude)
        let south = latitudes.min() ?? first.latitude
        let north = latitudes.max() ?? first.latitude
        let latitudeSpan = max((north - south) * paddingFactor, minimumSpan)
        let latitudeMiddle = (south + north) / 2
        var bottom = latitudeMiddle - latitudeSpan / 2
        var top = latitudeMiddle + latitudeSpan / 2
        if bottom < -90 {
            top = min(90, top + (-90 - bottom))
            bottom = -90
        }
        if top > 90 {
            bottom = max(-90, bottom - (top - 90))
            top = 90
        }

        // Longitude: the shortest arc that holds every point.
        let arc = shortestArc(of: valid.map(\.longitude))
        let longitudeSpan = min(360, max(arc.length * paddingFactor, minimumSpan))
        let center = GeoCoordinate(latitude: (bottom + top) / 2, longitude: normalized(arc.start + arc.length / 2))
        return CoordinateRegion(center: center, latitudeDelta: top - bottom, longitudeDelta: longitudeSpan)
    }

    /// Signed difference in degrees from `from` to `to`, in -180...180.
    static func longitudeDifference(from: Double, to: Double) -> Double {
        var difference = (to - from).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }

    /// Longitude folded into -180...180.
    static func normalized(_ longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// The shortest arc, going east from `start`, that covers every longitude. It skips the
    /// largest gap between neighbors, so two points either side of the 180th meridian span a
    /// fraction of a degree rather than the whole globe.
    static func shortestArc(of longitudes: [Double]) -> (start: Double, length: Double) {
        let sorted = longitudes.map(normalized).sorted()
        guard let lowest = sorted.first, let highest = sorted.last, sorted.count > 1 else {
            return (sorted.first ?? 0, 0)
        }
        var largestGap = lowest + 360 - highest
        var start = lowest
        for index in 1..<sorted.count {
            let gap = sorted[index] - sorted[index - 1]
            if gap > largestGap {
                largestGap = gap
                start = sorted[index]
            }
        }
        return (start, 360 - largestGap)
    }
}

extension GeoCoordinate {
    /// Great-circle distance in meters (haversine, mean Earth radius). Used only for the Map's
    /// straight-line note, never for travel time.
    public func distance(to other: GeoCoordinate) -> Double {
        let radius = 6_371_008.8
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let deltaLat = (other.latitude - latitude) * .pi / 180
        let deltaLon = MapCameraFit.longitudeDifference(from: longitude, to: other.longitude) * .pi / 180
        let haversine = sin(deltaLat / 2) * sin(deltaLat / 2) + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        // Rounding can push the value just past 1 for nearly antipodal points; keep the square roots real.
        let a = min(1, max(0, haversine))
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Point halfway between two coordinates on the map, taking the short way around the 180th
    /// meridian. Where the schematic line's label sits.
    public func midpoint(to other: GeoCoordinate) -> GeoCoordinate {
        let difference = MapCameraFit.longitudeDifference(from: longitude, to: other.longitude)
        return GeoCoordinate(
            latitude: (latitude + other.latitude) / 2,
            longitude: MapCameraFit.normalized(longitude + difference / 2)
        )
    }
}
