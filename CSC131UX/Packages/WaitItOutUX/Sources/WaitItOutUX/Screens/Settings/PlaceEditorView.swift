import SwiftUI

/// Edits home or campus (step 0006): a name and decimal-degree coordinates, validated as they
/// are typed through `PlaceInput`. Nothing changes until Save, which applies the whole place at
/// once so a half-typed coordinate never reaches a commute request. No location permission,
/// address search, or network lookup is used.
@MainActor
struct PlaceEditorView: View {
    let model: WaitItOutModel
    let role: PlaceRole

    @Environment(\.dismiss) private var dismiss
    @State private var input: PlaceInput
    private let original: PlaceInput

    init(model: WaitItOutModel, role: PlaceRole) {
        self.model = model
        self.role = role
        let current = PlaceInput(place: model.places[role])
        original = current
        _input = State(initialValue: current)
    }

    private var issues: [PlaceIssue] { input.issues }

    private var sampleInput: PlaceInput {
        PlaceInput(place: model.samplePlaces[role])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $input.name, prompt: Text(role == .home ? "For example, Apartment" : "For example, Main campus"))
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier(AccessibilityID.placeEditorName)
                    issueRows(.name)
                } header: {
                    Text("Name")
                }

                Section {
                    LabeledContent("Latitude") {
                        TextField("Latitude", text: $input.latitude, prompt: Text("38.5610"))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Latitude, decimal degrees")
                            .accessibilityIdentifier(AccessibilityID.placeEditorLatitude)
                    }
                    issueRows(.latitude)
                    LabeledContent("Longitude") {
                        TextField("Longitude", text: $input.longitude, prompt: Text("-121.4237"))
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Longitude, decimal degrees")
                            .accessibilityIdentifier(AccessibilityID.placeEditorLongitude)
                    }
                    issueRows(.longitude)
                } header: {
                    Text("Coordinates")
                } footer: {
                    Text("Decimal degrees (WGS-84): latitude from -90 to 90, longitude from -180 to 180, such as 38.5610 and -121.4237. Copy them from any map app. \(DataSourceWording.coordinateEntryNote(usesLiveBackend: model.usesLiveBackend))")
                }

                Section {
                    if input == sampleInput {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            DemoBadge(text: "SAMPLE")
                            Text("These are the labeled sample values. \(role == .home ? SampleLocation.demoHome.provenance : SampleLocation.demoCampus.provenance)")
                                .font(.footnote)
                        }
                    } else {
                        Button {
                            input = sampleInput
                        } label: {
                            Label("Use Sample \(role.title)", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityIdentifier(AccessibilityID.placeEditorUseSample)
                        .accessibilityHint("Fills in the labeled sample values. Nothing changes until you save.")
                    }
                } footer: {
                    Text(role == .home
                         ? "Every leave-home time is calculated for a trip from home to campus. Saving recalculates them."
                         : "Every activity goes to the campus, so saving recalculates every leave-home time. The campus time zone stays \(model.campusTimeZone.identifier).")
                }
            }
            .navigationTitle(role.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.placeEditorCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.applyPlaceInput(input, for: role).isEmpty {
                            dismiss()
                        }
                    }
                    .disabled(!issues.isEmpty || input == original)
                    .accessibilityIdentifier(AccessibilityID.placeEditorSave)
                    .accessibilityHint(issues.isEmpty ? "Saves the \(role.title.lowercased()) location" : "Fix the issues above first")
                }
            }
            .interactiveDismissDisabled(input != original)
        }
        // One container element carries the sheet's identifier; its controls keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.placeEditorSheet)
    }

    @ViewBuilder
    private func issueRows(_ field: PlaceField) -> some View {
        ForEach(issues.filter { $0.field == field }, id: \.self) { issue in
            Label(issue.message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(issue.message)
                .accessibilityIdentifier(AccessibilityID.placeEditorIssue)
        }
    }
}

/// Settings rows for home and campus (step 0006): each place with its coordinates and a SAMPLE
/// badge while it holds the labeled sample value, an edit action, and the reset action.
@MainActor
struct PlacesSettingsSection: View {
    let model: WaitItOutModel
    let onEdit: (PlaceRole) -> Void

    var body: some View {
        Section {
            ForEach(PlaceRole.allCases) { role in
                placeRow(role)
            }
            Button {
                model.resetPlacesToSample()
            } label: {
                Label("Reset to Sample Locations", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.usesSamplePlaces)
            .accessibilityIdentifier(AccessibilityID.settingsResetPlaces)
            .accessibilityHint("Restores the labeled sample home and campus and recalculates every leave-home time")
        } header: {
            Text("Home and campus")
        } footer: {
            Text("Every trip goes from home to campus, and every activity goes to the campus. Values marked SAMPLE are demo locations (\(SampleLocation.demoHome.name) near Elk Grove, \(SampleLocation.demoCampus.name) near Sacramento State), not anyone's address. \(DataSourceWording.placesNote(usesLiveBackend: model.usesLiveBackend)) \(model.preferencesPersistenceDescription)")
        }
    }

    private func placeRow(_ role: PlaceRole) -> some View {
        let place = model.places[role]
        return Button {
            onEdit(role)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: role.systemImage)
                    .foregroundStyle(MapPinStyle.color(for: role))
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        Text(role.title)
                            .font(.subheadline.weight(.semibold))
                        if model.isSamplePlace(role) {
                            DemoBadge(text: "SAMPLE")
                        }
                    }
                    Text(place.name)
                    Text(place.coordinateText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                Spacer(minLength: Spacing.sm)
                Text("Edit")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityLabel("\(role.title): \(place.name)\(model.isSamplePlace(role) ? ", sample data" : ""), \(place.coordinateText)")
        .accessibilityHint("Edits the name and coordinates")
        .accessibilityIdentifier(AccessibilityID.settingsPlace(role))
    }
}

#Preview("Place editor - sample home") {
    PlaceEditorView(model: .preview(initialTab: .settings), role: .home)
}
