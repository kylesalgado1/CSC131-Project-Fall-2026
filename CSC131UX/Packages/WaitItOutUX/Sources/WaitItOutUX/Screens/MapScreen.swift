import MapKit
import SwiftUI

/// Map tab (step 0006). Built around the saved next campus trip: the next-trip card shows the
/// event, the ideal arrival, the read-only leave-home time, the test drive duration, and the
/// estimate's source and age. Home and campus from Settings appear as pins joined by a dashed
/// line labeled as a schematic connection, never a driving route, and the camera fits both.
/// An always-visible "Demo estimate" label sits in the navigation bar while the test provider
/// is in use, and a plain "Team backend" label takes its place while the team backend is (stage
/// S3). In the demo no location permission, routing, geocoding, or traffic data is
/// involved. With the live backend, a driving route the backend supplied replaces the dashed
/// line, drawn solid and labeled with its source; until one arrives, and whenever it cannot be
/// loaded, the dashed line and its schematic labels stay. The cards are plain SwiftUI, so the
/// trip summary stays when map tiles cannot load without a network connection.
@MainActor
public struct MapScreen: View {
    let model: WaitItOutModel

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraPosition: MapCameraPosition
    @State private var styleChoice: MapStyleChoice = .standard
    @State private var showsBothPlaces = true
    /// Current instant from the injected clock, refreshed at each whole minute while the Map
    /// tab is on screen. `nil` until the first tick.
    @State private var now: Date?

    /// Public since step 0008 so the team can place this screen in its own tab bar.
    public init(model: WaitItOutModel) {
        self.model = model
        _cameraPosition = State(initialValue: Self.fittedCamera(for: model.places, route: model.routeState.geometry, fallback: model.sampleCampus))
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                map
                    .safeAreaInset(edge: .bottom) {
                        cards(maxHeight: proxy.size.height * 0.6)
                    }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.usesTestCommute {
                    ToolbarItem(placement: .topBarLeading) {
                        DemoEstimateLabel(scenario: model.testCommuteScenario)
                    }
                } else if model.usesLiveBackend {
                    ToolbarItem(placement: .topBarLeading) {
                        LiveDataLabel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Map style", selection: $styleChoice) {
                        ForEach(MapStyleChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityID.mapStylePicker)
                }
            }
            .task {
                await runClock()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    now = model.currentDate()
                    model.refreshDepartures()
                }
            }
            .onChange(of: model.places) { _, places in
                fit(places)
            }
            .onChange(of: model.routeState.geometry) { _, _ in
                // A route that arrived or changed is brought into view whole.
                fit(model.places)
            }
        }
    }

    private var map: some View {
        let home = model.places.home
        let campus = model.places.campus
        // A solid line is drawn only for a route a provider supplied. In every other state the
        // dashed straight line keeps its schematic label: a straight line is never a route.
        let route = model.routeState.geometry
        return Map(position: $cameraPosition, interactionModes: .all) {
            Marker("\(PlaceRole.home.title): \(home.name)", systemImage: PlaceRole.home.systemImage, coordinate: home.coordinate.locationCoordinate)
                .tint(MapPinStyle.color(for: .home))
            Marker("\(PlaceRole.campus.title): \(campus.name)", systemImage: PlaceRole.campus.systemImage, coordinate: campus.coordinate.locationCoordinate)
                .tint(MapPinStyle.color(for: .campus))
            if let route {
                MapPolyline(coordinates: route.points.map(\.locationCoordinate))
                    .stroke(Color.accentColor, lineWidth: 4)
                Annotation(MapRouteText.annotation(for: route), coordinate: (route.middlePoint ?? home.coordinate.midpoint(to: campus.coordinate)).locationCoordinate, anchor: .center) {
                    Image(systemName: "car.fill")
                        .font(.caption.weight(.bold))
                        .padding(Spacing.xs)
                        .background(.thinMaterial, in: Circle())
                        .accessibilityHidden(true)
                }
            } else {
                MapPolyline(coordinates: [home.coordinate.locationCoordinate, campus.coordinate.locationCoordinate], contourStyle: .straight)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 8]))
                Annotation("Schematic line, not a route", coordinate: home.coordinate.midpoint(to: campus.coordinate).locationCoordinate, anchor: .center) {
                    Image(systemName: "line.diagonal")
                        .font(.caption.weight(.bold))
                        .padding(Spacing.xs)
                        .background(.thinMaterial, in: Circle())
                        .accessibilityHidden(true)
                }
            }
        }
        .mapStyle(styleChoice.mapStyle)
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let visible = Self.coordinateRegion(context.region)
            showsBothPlaces = visible.contains(home.coordinate) && visible.contains(campus.coordinate)
        }
        .accessibilityIdentifier(AccessibilityID.mapView)
        .accessibilityLabel("Map with \(PlaceRole.home.title.lowercased()) \(home.name) and \(PlaceRole.campus.title.lowercased()) \(campus.name), \(MapRouteText.mapLineDescription(for: model.routeState))")
    }

    /// The trip and places cards, capped so the map stays visible; they scroll when larger,
    /// for example at accessibility text sizes.
    private func cards(maxHeight: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            cardStack
            ScrollView {
                cardStack
            }
        }
        .frame(maxWidth: 560, maxHeight: max(160, maxHeight), alignment: .bottom)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }

    private var cardStack: some View {
        VStack(spacing: Spacing.md) {
            NextTripCard(
                model: model,
                now: now ?? model.currentDate(),
                formatter: OccurrenceFormatter(calculator: model.weekCalculator, locale: locale)
            )
            MapPlacesCard(model: model, showsBothPlaces: showsBothPlaces) {
                fit(model.places)
            }
        }
    }

    private func fit(_ places: CommutePlaces) {
        withAnimation {
            cameraPosition = Self.fittedCamera(for: places, route: model.routeState.geometry, fallback: model.sampleCampus)
        }
        showsBothPlaces = true
    }

    /// Refreshes `now` at each whole minute and re-plans leave-home times, which starts a
    /// calculation for any occurrence that entered the horizon and refreshes stale estimates.
    /// Cancelled when the tab is hidden, so nothing ticks in the background.
    @MainActor
    private func runClock() async {
        while !Task.isCancelled {
            let instant = model.currentDate()
            now = instant
            model.refreshDepartures()
            let second = model.weekCalculator.calendar.component(.second, from: instant)
            do {
                try await Task.sleep(for: .seconds(max(1, 60 - second)))
            } catch {
                return
            }
        }
    }

    /// The camera that fits home and campus and, when a driving route is shown, every point of
    /// it (`MapCameraFit`), or the sample campus when no region can be formed.
    static func fittedCamera(for places: CommutePlaces, route: RouteGeometry? = nil, fallback: SampleLocation) -> MapCameraPosition {
        guard let region = MapCameraFit.region(fitting: [places.home.coordinate, places.campus.coordinate] + (route?.points ?? [])) else {
            return .region(MKCoordinateRegion(center: fallback.coordinate, latitudinalMeters: 1_600, longitudinalMeters: 1_600))
        }
        return .region(MKCoordinateRegion(
            center: region.center.locationCoordinate,
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)
        ))
    }

    static func coordinateRegion(_ region: MKCoordinateRegion) -> CoordinateRegion {
        CoordinateRegion(
            center: GeoCoordinate(latitude: region.center.latitude, longitude: region.center.longitude),
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
    }
}

/// Equatable wrapper so a picker can drive `MapStyle`, which is not itself Equatable.
enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .hybrid: return "Hybrid"
        case .imagery: return "Satellite"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .flat)
        case .hybrid: return .hybrid
        case .imagery: return .imagery
        }
    }
}

#Preview("Map - empty schedule") {
    MapScreen(model: .preview())
}

#Preview("Map - next trip, sample schedule") {
    MapScreen(model: .preview(activities: WaitItOutModel.previewSampleActivities()))
}

#Preview("Map - Slow scenario") {
    MapScreen(model: .preview(activities: WaitItOutModel.previewSampleActivities(), commute: .init(scenario: .slow)))
}

#Preview("Map - Unavailable scenario") {
    MapScreen(model: .preview(activities: WaitItOutModel.previewSampleActivities(), commute: .init(scenario: .unavailable)))
}

#Preview("Map - estimate failed") {
    MapScreen(model: .preview(activities: WaitItOutModel.previewSampleActivities(), commute: .init(scenario: .error)))
}

#Preview("Map - live data, monitored trip") {
    MapScreen(model: .previewLive(initialTab: .map))
}

#Preview("Map - large text") {
    MapScreen(model: .preview(activities: WaitItOutModel.previewSampleActivities()))
        .environment(\.dynamicTypeSize, .accessibility3)
}
