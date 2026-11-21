import Foundation

/// Home and campus (step 0006). Both are typed `CommutePlace` values in `UserPreferences`,
/// entered in Settings without location permission, geocoding, or network access.
///
/// Every trip goes from home to campus. Activities store a copy of their destination; one
/// whose destination id is the campus id (`sampleCampus.destinationID`) always resolves to
/// the campus currently set, so editing the campus re-points every campus activity without
/// rewriting storage. Any change recalculates every leave-home time and the editor's preview.
extension WaitItOutModel {
    /// Home and campus as set in Settings.
    public var places: CommutePlaces {
        preferences.places
    }

    /// The labeled sample pair "Reset to sample locations" restores.
    public var samplePlaces: CommutePlaces {
        CommutePlaces.sample(home: sampleHome, campus: sampleCampus)
    }

    /// True when `role` still holds its labeled sample value, so Settings and the Map mark it SAMPLE.
    public func isSamplePlace(_ role: PlaceRole) -> Bool {
        places[role] == samplePlaces[role]
    }

    /// True when both places are the labeled samples.
    public var usesSamplePlaces: Bool {
        places == samplePlaces
    }

    /// The campus every activity goes to, as currently set.
    public var campusDestination: Destination {
        Destination(id: sampleCampus.destinationID, name: places.campus.name, coordinate: places.campus.coordinate)
    }

    /// Where a stored or draft destination actually is: the current campus for the campus id,
    /// the stored copy otherwise.
    public func resolvedDestination(_ destination: Destination) -> Destination {
        destination.id == sampleCampus.destinationID ? campusDestination : destination
    }

    /// Settings place editor: validates the typed name and coordinates and applies them.
    /// Returns every issue and changes nothing when the input is unusable.
    @discardableResult
    public func applyPlaceInput(_ input: PlaceInput, for role: PlaceRole) -> [PlaceIssue] {
        switch input.place() {
        case .success(let place):
            setPlace(place, for: role)
            return []
        case .failure(let error):
            return error.issues
        }
    }

    /// Stores a place, persists the preferences, and recalculates. No-op when unchanged.
    public func setPlace(_ place: CommutePlace, for role: PlaceRole) {
        guard preferences.places[role] != place else { return }
        preferences.places[role] = place
        persistPreferences()
        placesDidChange()
    }

    /// Restores both labeled sample locations. No-op when they are already in use.
    public func resetPlacesToSample() {
        guard preferences.places != samplePlaces else { return }
        preferences.places = samplePlaces
        persistPreferences()
        placesDidChange()
    }

    /// The trip for a saved occurrence: home to its resolved destination by its ideal arrival.
    func commuteRequest(for occurrence: ActivityOccurrence) -> CommuteRequest {
        CommuteRequest(
            occurrence: occurrence,
            origin: places.home,
            destination: resolvedDestination(occurrence.activity.destination)
        )
    }

    /// The trip for the pending draft's first occurrence.
    func commuteRequest(for draft: ActivityDraft) -> CommuteRequest {
        CommuteRequest(
            draft: draft,
            origin: places.home,
            destination: resolvedDestination(draft.destination),
            fallbackZone: campusTimeZone
        )
    }

    /// Every request changes with home or campus, so each one is asked again from scratch,
    /// and so is the Map's route when the live backend supplies one.
    func placesDidChange() {
        refreshDepartures()
        syncDraftDeparture()
        refreshRoute()
    }
}
