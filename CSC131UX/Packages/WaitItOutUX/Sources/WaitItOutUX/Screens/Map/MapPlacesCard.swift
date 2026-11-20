import SwiftUI

/// The Map's home and campus summary (step 0006): both places in words, the schematic-line
/// legend (or the driving route's source when the live backend supplied one), whether the
/// camera shows both pins, and the fit action. Everything here is text, so
/// it stays readable when map tiles cannot load without a network connection.
@MainActor
struct MapPlacesCard: View {
    let model: WaitItOutModel
    /// True when the last camera position showed both pins.
    let showsBothPlaces: Bool
    let onFit: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Home and campus")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(PlaceRole.allCases) { role in
                placeLine(role)
            }
            Label(schematicText, systemImage: model.routeState.geometry == nil ? "line.diagonal" : "car")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.mapSchematicNote)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.mapDemoStatus)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    buttons
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    buttons
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.mapPlacesCard)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onFit) {
            Label("Show Home and Campus", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(AccessibilityID.mapRecenterButton)
        .accessibilityHint("Moves the map so both pins are in view")
        Button {
            model.selectedTab = .settings
        } label: {
            Label("Edit in Settings", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(AccessibilityID.mapOpenSettings)
        .accessibilityHint("Opens Settings, where home and campus are changed")
    }

    private func placeLine(_ role: PlaceRole) -> some View {
        let place = model.places[role]
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: role.systemImage)
                .foregroundStyle(MapPinStyle.color(for: role))
                .accessibilityHidden(true)
            Text("\(role.title): \(place.name)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if model.isSamplePlace(role) {
                DemoBadge(text: "SAMPLE")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.mapPlace(role))
    }

    /// The note under the places: the schematic-line legend, or, only when the live backend
    /// supplied a driving route, where that route comes from and how long it is.
    private var schematicText: String {
        if let route = model.routeState.geometry {
            let distance = Measurement(value: route.distanceMiles, unit: UnitLength.miles)
                .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
            return MapRouteText.note(for: route, distance: distance)
        }
        let meters = model.places.home.coordinate.distance(to: model.places.campus.coordinate)
        let distance = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
        return MapRouteText.schematicNote(distance: distance)
    }

    private var statusText: String {
        MapRouteText.status(showsBothPlaces: showsBothPlaces, usesLiveBackend: model.usesLiveBackend, route: model.routeState)
    }
}

/// Pin colors shared by the map markers and the card's place lines.
enum MapPinStyle {
    static func color(for role: PlaceRole) -> Color {
        switch role {
        case .home: return .teal
        case .campus: return .indigo
        }
    }
}
