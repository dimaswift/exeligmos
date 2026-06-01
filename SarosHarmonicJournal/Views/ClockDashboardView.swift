import SwiftData
import SwiftUI

struct ClockDashboardView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TrackedEntity.createdAt, order: .forward) private var entities: [TrackedEntity]
    @Query(sort: \JournalRecord.createdAt, order: .reverse) private var records: [JournalRecord]

    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var isAddingEntity = false
    @State private var captureEntity: TrackedEntity?
    @State private var now = Date()

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if let closestFlip {
                Section("Next flip") {
                    ClosestFlipCard(
                        entity: closestFlip.entity,
                        reading: closestFlip.reading,
                        countdown: countdownText(for: closestFlip.reading.timeUntilNextFlip)
                    ) {
                        captureEntity = closestFlip.entity
                    }
                }
            }

            Section("Threads") {
                if entities.isEmpty {
                    ContentUnavailableView {
                        VStack(spacing: 12) {
                            OctalGlyph(value: String(repeating: "7", count: harmonicDepth), depth: harmonicDepth, color: .secondary)
                                .frame(width: 56, height: 56)
                            Text("No threads yet")
                        }
                    } description: {
                        Text("Add an anchor date to start a private Saros clock.")
                    }
                } else {
                    ForEach(entities) { entity in
                        let reading = reading(for: entity)
                        NavigationLink {
                            EntityDetailView(entity: entity)
                        } label: {
                            EntityCardView(
                                entity: entity,
                                reading: reading,
                                latestRecord: latestRecord(for: entity)
                            )
                        }
                    }
                    .onDelete(perform: deleteEntities)
                }
            }

            if let resonance = nextResonance {
                Section("Next resonance") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(resonance.entityIDs.count) threads flip close together")
                            .font(.headline)
                        Text("\(JournalFormatters.dateTime.string(from: resonance.startDate)) - \(JournalFormatters.dateTime.string(from: resonance.endDate))")
                            .foregroundStyle(.secondary)
                        Text("Saros \(resonance.sarosValues.map(String.init).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingEntity = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add thread")
            }
        }
        .sheet(isPresented: $isAddingEntity) {
            NavigationStack {
                EntityEditorView()
            }
        }
        .sheet(item: $captureEntity) { entity in
            NavigationStack {
                CaptureView(entity: entity, harmonicDepth: harmonicDepth) {
                    now = Date()
                }
            }
        }
        .onReceive(countdownTimer) { date in
            now = date
        }
    }

    private var closestFlip: (entity: TrackedEntity, reading: SarosClockReading)? {
        entityReadings.min { lhs, rhs in
            lhs.reading.timeUntilNextFlip < rhs.reading.timeUntilNextFlip
        }
    }

    private var entityReadings: [(entity: TrackedEntity, reading: SarosClockReading)] {
        entities.compactMap { entity in
            guard let reading = reading(for: entity) else { return nil }
            return (entity, reading)
        }
    }

    private var nextResonance: ResonanceEvent? {
        let flips = entities.compactMap { entity -> EntityFlip? in
            guard let reading = try? services.clockService.reading(
                saros: entity.saros,
                date: now,
                harmonicDepth: harmonicDepth
            ) else {
                return nil
            }

            let nextIndex = min(reading.binIndex + 1, reading.binCount - 1)
            return EntityFlip(
                entityID: entity.id,
                entityTitle: entity.displayTitle,
                date: reading.nextFlipDate,
                saros: entity.saros,
                octalAddress: String(nextIndex, radix: 8).leftPadded(toLength: harmonicDepth, withPad: "0")
            )
        }

        return ResonanceDetector.detectResonances(flips: flips, window: 60 * 60)
            .filter { $0.endDate >= now }
            .first
    }

    private func reading(for entity: TrackedEntity) -> SarosClockReading? {
        try? services.clockService.reading(
            saros: entity.saros,
            date: now,
            harmonicDepth: harmonicDepth
        )
    }

    private func latestRecord(for entity: TrackedEntity) -> JournalRecord? {
        records.first { $0.entityID == entity.id }
    }

    private func countdownText(for interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded(.up)), 0)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        return "\(minutes)m \(seconds)s"
    }

    private func deleteEntities(at offsets: IndexSet) {
        for offset in offsets {
            modelContext.delete(entities[offset])
        }
        try? modelContext.save()
    }
}

private struct ClosestFlipCard: View {
    let entity: TrackedEntity
    let reading: SarosClockReading
    let countdown: String
    let record: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth)
                    .frame(width: 74, height: 74)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(entity.displayTitle)
                        .font(.headline)
                    Text("Saros \(reading.saros) · \(reading.octalAddress)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(countdown)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .contentTransition(.numericText())
                }

                Spacer()
            }

            HStack {
                Text("Flip \(JournalFormatters.dateTime.string(from: reading.nextFlipDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: record) {
                    Image(systemName: "record.circle.fill")
                        .font(.title3)
                        .frame(width: 44, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Record \(entity.displayTitle)")
            }
        }
        .padding(.vertical, 6)
    }
}

private struct EntityCardView: View {
    let entity: TrackedEntity
    let reading: SarosClockReading?
    let latestRecord: JournalRecord?

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                Text(entity.displayTitle)
                    .font(.headline)
                Text("Saros \(entity.saros) · \(reading?.octalAddress ?? "----")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let reading {
                    Text("Next flip in \(reading.timeUntilNextFlip.compactDuration)")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }

                if let latestRecord {
                    Text(latestRecord.text ?? latestRecord.emoji ?? latestRecord.triggerType.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let reading {
                DynamicFlipGlyph(reading: reading)
                    .frame(width: 42, height: 42)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var avatar: some View {
        if let reading {
            OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth)
                .frame(width: 48, height: 48)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else if let emoji = entity.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 30))
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            OctalGlyph(value: String(repeating: "7", count: JournalSettings.defaultHarmonicDepth), color: .secondary)
                .frame(width: 48, height: 48)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DynamicFlipGlyph: View {
    let reading: SarosClockReading

    var body: some View {
        TimelineView(.periodic(from: currentBinStart, by: refreshPeriod)) { context in
            OctalGlyph(
                value: dynamicAddress(at: context.date),
                depth: reading.harmonicDepth,
                color: .cyan
            )
        }
        .accessibilityLabel("Flip countdown glyph")
    }

    private var binDuration: TimeInterval {
        reading.nextEclipse.date.timeIntervalSince(reading.previousEclipse.date) / Double(reading.binCount)
    }

    private var currentBinStart: Date {
        reading.nextFlipDate.addingTimeInterval(-binDuration)
    }

    private var refreshPeriod: TimeInterval {
        max(binDuration / Double(reading.binCount), 1.0 / 30.0)
    }

    private func dynamicAddress(at date: Date) -> String {
        let progress = min(max(date.timeIntervalSince(currentBinStart) / binDuration, 0), 1 - Double.ulpOfOne)
        let subIndex = min(Int(floor(progress * Double(reading.binCount))), reading.binCount - 1)
        return String(subIndex, radix: 8).leftPadded(toLength: reading.harmonicDepth, withPad: "0")
    }
}

private struct EntityDetailView: View {
    @EnvironmentObject private var services: AppServices
    @Query(sort: \JournalRecord.eventDate, order: .reverse) private var records: [JournalRecord]

    let entity: TrackedEntity
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth
    @State private var isCapturing = false
    @State private var now = Date()

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                if let reading = try? services.clockService.reading(
                    saros: entity.saros,
                    date: now,
                    harmonicDepth: harmonicDepth
                ) {
                    HStack(spacing: 16) {
                        OctalGlyph(value: reading.octalAddress, depth: reading.harmonicDepth)
                            .frame(width: 72, height: 72)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reading.octalAddress)
                                .font(.system(.title, design: .monospaced))
                            Text("Next flip \(JournalFormatters.dateTime.string(from: reading.nextFlipDate))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    MetadataRow(title: "Previous", value: JournalFormatters.date.string(from: reading.previousEclipse.date))
                    MetadataRow(title: "Next", value: JournalFormatters.date.string(from: reading.nextEclipse.date))
                }

                MetadataRow(title: "Anchor", value: JournalFormatters.date.string(from: entity.anchorDate))
                if let notes = entity.notes, !notes.isEmpty {
                    Text(notes)
                }
            }

            Section("Records") {
                let entityRecords = records.filter { $0.entityID == entity.id }
                if entityRecords.isEmpty {
                    Text("No records yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entityRecords) { record in
                        NavigationLink {
                            JournalRecordDetailView(record: record, entityTitle: entity.displayTitle)
                        } label: {
                            JournalRecordRow(record: record, entityTitle: entity.displayTitle)
                        }
                    }
                }
            }
        }
        .navigationTitle(entity.displayTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCapturing = true
                } label: {
                    Label("Rec", systemImage: "record.circle")
                }
            }
        }
        .sheet(isPresented: $isCapturing) {
            NavigationStack {
                CaptureView(entity: entity, harmonicDepth: harmonicDepth) {
                    now = Date()
                }
            }
        }
        .onReceive(countdownTimer) { date in
            now = date
        }
    }
}
