import SwiftUI

/// The Map's next-trip summary (steps 0005 and 0006): the next saved activity that has not
/// started, its event time and ideal arrival, the read-only leave-home time, where the travel
/// time came from and how old it is, and, with the test provider, the simulated drive and
/// scenario. While reminders are on, the compact reminder preview follows (step 0007). In the
/// Live data mode (stage S3) the server's monitoring status takes the preview's place, with the
/// server's plan for this trip and "I've Left" while the server is monitoring it. When
/// nothing is scheduled the card offers a calendar setup action instead.
@MainActor
struct NextTripCard: View {
    let model: WaitItOutModel
    /// Instant from the Map's minute tick, read through the injected clock.
    let now: Date
    let formatter: OccurrenceFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Label("Next trip", systemImage: "car")
                    .font(.headline)
                Spacer(minLength: Spacing.sm)
                if model.usesTestCommute {
                    DemoBadge(text: "TEST DATA")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.mapNextTrip)
    }

    @ViewBuilder
    private var content: some View {
        if let trip = model.nextTrip(at: now) {
            tripContent(trip)
        } else if model.activities.isEmpty {
            emptyContent
        } else {
            nothingUpcomingContent
        }
    }

    private func tripContent(_ trip: NextTrip) -> some View {
        let occurrence = trip.occurrence
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(occurrence.activity.title)
                    .font(.subheadline.weight(.semibold))
                if occurrence.isSample {
                    DemoBadge(text: "SAMPLE")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.mapNextTripTitle)
            Text(formatter.nextTripScheduleText(for: occurrence))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DepartureRows(
                state: trip.state,
                formatter: formatter,
                now: now,
                identifierPrefix: AccessibilityID.mapNextTripDeparture,
                usesLiveBackend: model.usesLiveBackend,
                onRetry: { model.retryDepartures() }
            )
            .fixedSize(horizontal: false, vertical: true)
            if model.usesTestCommute {
                Label(
                    formatter.simulationText(
                        scenario: model.testCommuteScenario,
                        testDuration: model.testCommuteDuration,
                        travelTime: model.simulatedTravelTime
                    ),
                    systemImage: "testtube.2"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.mapNextTripSimulation)
            }
            if model.usesLiveBackend {
                if model.showsMonitoringOnMap {
                    Divider()
                    MonitoringStatusView(
                        model: model,
                        identifierPrefix: AccessibilityID.mapMonitoring,
                        isCompact: true,
                        trip: occurrence,
                        now: now
                    )
                    if let summary = model.monitoringSummary(for: occurrence) {
                        TripDepartedControl(
                            summary: summary,
                            buttonIdentifier: AccessibilityID.mapNextTripLeft,
                            statusIdentifier: AccessibilityID.mapNextTripLeftStatus,
                            isBordered: true,
                            onMarkDeparted: {
                                Task { await model.markDeparted(occurrence.id, arriveBy: occurrence.idealArrival) }
                            }
                        )
                    }
                }
            } else if model.remindersEnabled || model.reminderSync == .failed {
                Divider()
                ReminderPreviewView(model: model, identifierPrefix: AccessibilityID.mapReminderPreview, isCompact: true)
            }
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(model.activitiesStatus.failureMessage ?? "No activities yet. Add one with its start, end, and ideal arrival, and the time to leave home appears here.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.startCalendarSetup()
            } label: {
                Label("Add Activity", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.mapNextTripAddActivity)
            .accessibilityHint("Opens the Calendar with a new activity for today")
            Text("The labeled sample schedule can also be loaded in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var nothingUpcomingContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Nothing starts in the next \(DepartureHorizon.lookaheadDays) days, so there is no trip to plan.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.selectedTab = .calendar
            } label: {
                Label("Open Calendar", systemImage: "calendar")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.mapNextTripOpenCalendar)
            .accessibilityHint("Shows the Calendar, where activities are added and edited")
        }
    }
}
