import ActivityKit
import SwiftUI
import WidgetKit

struct ThreadTrackingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ThreadTrackingAttributes.self) { context in
            ThreadTrackingLockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(deepLinkURL(for: context.attributes.threadID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveTrackingGlyphView(context: context, size: 64)
                }

                DynamicIslandExpandedRegion(.center) {
                    LiveTrackingCenterView(context: context)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    LiveTrackingRarityIconView(context: context)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    LiveTrackingTimerView(context: context, compact: false)
                }
            } compactLeading: {
                LiveTrackingGlyphView(context: context, size: 24)
            } compactTrailing: {
                LiveTrackingTimerView(context: context, compact: true)
            } minimal: {
                LiveTrackingRarityIconView(context: context)
            }
            .keylineTint(Color(hexString: context.state.rarityColorHex))
            .widgetURL(deepLinkURL(for: context.attributes.threadID))
        }
    }

    private func deepLinkURL(for threadID: String) -> URL? {
        URL(string: "exeligmos://thread/\(threadID)")
    }
}

private struct ThreadTrackingLockScreenView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            lockScreenContent(payload: payload, now: timeline.date)
        }
    }

    private func lockScreenContent(payload: TrackingDisplayPayload, now: Date) -> some View {
        let color = Color(hexString: payload.rarityColorHex)

        return HStack(spacing: 22) {
            WidgetOctalGlyph(
                value: payload.glyph,
                depth: context.attributes.harmonicDepth,
                color: color,
                secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
            )
            .frame(width: 68, height: 68)
            .offset(x: 4, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(context.attributes.threadTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: payload.raritySymbolName)
                    Text(payload.rarityTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                TrackingCountdownText(
                    payload: payload,
                    now: now,
                    compact: false,
                    recordURL: URL(string: "exeligmos://record/\(context.attributes.threadID)")
                )
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
            .padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .foregroundStyle(.white)
    }
}

private struct LiveTrackingGlyphView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            WidgetOctalGlyph(
                value: payload.glyph,
                depth: context.attributes.harmonicDepth,
                color: Color(hexString: payload.rarityColorHex),
                secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
            )
            .frame(width: size, height: size)
            .offset(x: 4, y: 4)
        }
    }
}

private struct LiveTrackingCenterView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            let color = Color(hexString: payload.rarityColorHex)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.threadTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(payload.rarityOrderLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: payload.raritySymbolName)
                    Text(payload.rarityTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LiveTrackingRarityIconView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            Image(systemName: payload.raritySymbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(hexString: payload.rarityColorHex))
                .offset(x: -4, y: 3)
        }
    }
}

private struct LiveTrackingTimerView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            VStack(alignment: .leading, spacing: compact ? 0 : 6) {
                if !compact {
                    Text("Next flip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                TrackingCountdownText(
                    payload: payload,
                    now: timeline.date,
                    compact: compact,
                    recordURL: URL(string: "exeligmos://record/\(context.attributes.threadID)")
                )
                    .font(compact ? .caption2.weight(.semibold).monospacedDigit() : .title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(hexString: payload.rarityColorHex))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
