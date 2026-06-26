import SwiftUI
import WidgetKit

struct TrackedThreadEntry: TimelineEntry {
    let date: Date
    let snapshot: ThreadTrackingSnapshot?
}

struct TrackedThreadProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrackedThreadEntry {
        TrackedThreadEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackedThreadEntry) -> Void) {
        completion(TrackedThreadEntry(date: .now, snapshot: ThreadTrackingSharedStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackedThreadEntry>) -> Void) {
        let snapshot = ThreadTrackingSharedStore.load()
        let entry = TrackedThreadEntry(date: .now, snapshot: snapshot)
        let now = Date.now
        let refreshCandidates = [
            snapshot?.flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay),
            snapshot?.waveformEndDate
        ]
            .compactMap { $0 }
            .filter { $0 > now.addingTimeInterval(2) }
        let nextRefresh = refreshCandidates.min() ?? now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct TrackedThreadWidget: Widget {
    let kind = ThreadTrackingSharedStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrackedThreadProvider()) { entry in
            TrackedThreadWidgetView(entry: entry)
        }
        .configurationDisplayName("Live Tracking")
        .description("Shows the live waveform, glyph, and countdown for the current Saros spike.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct TrackedThreadWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: TrackedThreadEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    content(
                        for: snapshot,
                        payload: snapshot.displayPayload(at: timeline.date),
                        now: timeline.date
                    )
                }
                .widgetURL(snapshot.deepLinkURL)
            } else {
                emptyState
            }
        }
        .containerBackground(.black, for: .widget)
    }

    private func content(
        for snapshot: ThreadTrackingSnapshot,
        payload: TrackingDisplayPayload,
        now: Date
    ) -> some View {
        let color = Color(hexString: payload.rarityColorHex)

        return Group {
            switch family {
            case .systemMedium:
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(payload.displayEventName)
                            .font(.headline)
                            .lineLimit(1)
                        TrackingCountdownText(payload: payload, now: now, compact: false, recordURL: snapshot.recordURL)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(color)
                        HStack(spacing: 10) {
                            Text(payload.energyText)
                            Text(payload.momentumText)
                        }
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                        WidgetWaveformSegmentView(
                            samples: payload.waveformSamples ?? [],
                            spikeMarkers: payload.waveformSpikeMarkers ?? [],
                            color: color,
                            currentPosition: payload.waveformPosition(at: now)
                        )
                        .frame(height: 42)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    WidgetOctalGlyph(
                        value: payload.glyph,
                        depth: snapshot.harmonicDepth,
                        color: color,
                        secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
                    )
                    .frame(width: 72, height: 72)
                    .offset(x: 3, y: 3)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        WidgetOctalGlyph(
                            value: payload.glyph,
                            depth: snapshot.harmonicDepth,
                            color: color,
                            secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
                        )
                            .frame(width: 54, height: 54)
                            .offset(x: 3, y: 3)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(payload.energyText)
                            Text(payload.momentumText)
                        }
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                    }
                    Spacer(minLength: 0)
                    WidgetWaveformSegmentView(
                        samples: payload.waveformSamples ?? [],
                        spikeMarkers: payload.waveformSpikeMarkers ?? [],
                        color: color,
                        currentPosition: payload.waveformPosition(at: now)
                    )
                    .frame(height: 38)
                    Text(payload.displayEventName)
                        .font(.headline)
                        .lineLimit(1)
                    TrackingCountdownText(payload: payload, now: now, compact: true, recordURL: snapshot.recordURL)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(.white.opacity(0.75))
            Text("Live tracking off")
                .font(.headline)
            Text("Enable it from Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
        .foregroundStyle(.white)
    }
}

extension ThreadTrackingSnapshot {
    static let placeholder = ThreadTrackingSnapshot(
        threadID: UUID().uuidString,
        threadTitle: "Tracked Thread",
        saros: 145,
        harmonicDepth: 7,
        eventName: "148 Delta Duplex",
        energyPercent: 0.62,
        momentum: 0.34,
        waveDirectionRawValue: "ascending",
        waveformSamples: [0.12, 0.16, 0.22, 0.34, 0.51, 0.72, 0.94, 0.76, 0.48, 0.29, 0.22, 0.31, 0.46, 0.61, 0.68, 0.58, 0.43, 0.31, 0.24],
        waveformSpikeMarkers: [
            TrackingWaveformSpikeMarker(position: 0.34, energy: 0.94, colorHex: "#3D9BFF"),
            TrackingWaveformSpikeMarker(position: 0.74, energy: 0.68, colorHex: "#AF52DE")
        ],
        waveformStartDate: Date.now.addingTimeInterval(-6 * 60 * 60),
        waveformEndDate: Date.now.addingTimeInterval(6 * 60 * 60),
        glyph: "7210230",
        rarityRawValue: "rare-7",
        rarityTitle: "Omega Triplex",
        rarityOrderLabel: "XXX7777",
        raritySymbolName: "diamond",
        rarityColorHex: "#3D9BFF",
        raritySecondaryColorHex: "#3D9BFF",
        flipDate: Date.now.addingTimeInterval(2 * 60 * 60 + 17 * 60),
        createdAt: .now,
        nextGlyph: "7210231",
        nextRarityRawValue: "rare-1",
        nextRarityTitle: "Alpha Triplex",
        nextRarityOrderLabel: "XXX1111",
        nextRaritySymbolName: "circle.fill",
        nextRarityColorHex: "#8E8E93",
        nextRaritySecondaryColorHex: "#8E8E93",
        nextFlipDate: Date.now.addingTimeInterval(2 * 60 * 60 + 18 * 60)
    )
}
