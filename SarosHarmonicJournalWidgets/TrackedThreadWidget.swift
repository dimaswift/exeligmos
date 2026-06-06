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
        let nextRefresh = snapshot?.flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay) ?? Date.now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct TrackedThreadWidget: Widget {
    let kind = ThreadTrackingSharedStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrackedThreadProvider()) { entry in
            TrackedThreadWidgetView(entry: entry)
        }
        .configurationDisplayName("Tracked Thread")
        .description("Shows the glyph and countdown for the currently tracked thread.")
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
                HStack(spacing: 20) {
                    WidgetOctalGlyph(
                        value: payload.glyph,
                        depth: snapshot.harmonicDepth,
                        color: color,
                        secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
                    )
                        .frame(width: 78, height: 78)
                        .offset(x: 3, y: 3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.threadTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Saros \(snapshot.saros)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                        TrackingCountdownText(payload: payload, now: now, compact: false, recordURL: snapshot.recordURL)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(color)
                        rarityIndicator(payload: payload, color: color)
                    }
                    .padding(.leading, 2)
                    Spacer(minLength: 0)
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
                        Image(systemName: payload.raritySymbolName)
                            .foregroundStyle(color)
                            .offset(x: -2, y: 2)
                    }
                    Spacer(minLength: 0)
                    Text(snapshot.threadTitle)
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

    private func rarityIndicator(payload: TrackingDisplayPayload, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: payload.raritySymbolName)
            Text(payload.rarityTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(.white.opacity(0.75))
            Text("No tracked thread")
                .font(.headline)
            Text("Start tracking from a thread screen.")
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
        glyph: "7210230",
        rarityRawValue: "rare",
        rarityTitle: "Rare",
        rarityOrderLabel: "Order 3",
        raritySymbolName: "diamond",
        rarityColorHex: "#3D9BFF",
        raritySecondaryColorHex: "#3D9BFF",
        flipDate: Date.now.addingTimeInterval(2 * 60 * 60 + 17 * 60),
        createdAt: .now,
        nextGlyph: "7210231",
        nextRarityRawValue: "common",
        nextRarityTitle: "Common",
        nextRarityOrderLabel: "Order 2",
        nextRaritySymbolName: "circle.fill",
        nextRarityColorHex: "#8E8E93",
        nextRaritySecondaryColorHex: "#8E8E93",
        nextFlipDate: Date.now.addingTimeInterval(2 * 60 * 60 + 18 * 60)
    )
}
