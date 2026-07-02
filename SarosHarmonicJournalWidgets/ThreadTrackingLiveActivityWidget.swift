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
                    LiveTrackingGlyphView(context: context, size: 58)
                }

                DynamicIslandExpandedRegion(.center) {
                    LiveTrackingCenterView(context: context)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    LiveTrackingRarityIconView(context: context)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    LiveTrackingWaveTimerView(context: context)
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
        if threadID == ThreadTrackingSharedStore.activityLoggingID {
            return URL(string: "exeligmos://activity/stop")
        }
        if threadID == ThreadTrackingSharedStore.journalTrackingID {
            return URL(string: "exeligmos://saros")
        }
        return URL(string: "exeligmos://thread/\(threadID)")
    }
}

private struct ThreadTrackingLockScreenView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            lockScreenContent(payload: payload, now: timeline.date)
        }
    }

    private func lockScreenContent(payload: TrackingDisplayPayload, now: Date) -> some View {
        let color = Color(hexString: payload.rarityColorHex)
        let pulseWindow = WidgetPulseWindow(payload: payload, at: now)
        let signature = payload.waveSignature(at: now)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.displayEventName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(signature.type.emoji)
                        Text(signature.label)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    HStack(spacing: 10) {
                        Text(payload.energyText(at: now))
                        Text(payload.momentumText(at: now))
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                    TrackingCountdownText(
                        payload: payload,
                        now: now,
                        compact: false,
                        recordURL: actionURL(for: context.attributes.threadID)
                    )
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 8) {
                    WidgetOctalGlyph(
                        value: payload.glyph,
                        depth: context.attributes.harmonicDepth,
                        color: color,
                        secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
                    )
                    .frame(width: payload.isActivityLogging ? 72 : 48, height: payload.isActivityLogging ? 72 : 48)
                    .offset(x: 3, y: 3)
                    if !payload.isActivityLogging {
                        WidgetAuxiliaryGlyphsView(payload: payload, date: now, size: 30)
                    }
                }
            }
            if !payload.isActivityLogging {
                WidgetWaveformSegmentView(
                    samples: payload.waveformSamples ?? [],
                    samplePositions: payload.waveformSamplePositions ?? [],
                    spikeMarkers: payload.waveformSpikeMarkers ?? [],
                    color: color,
                    currentPosition: pulseWindow?.discretePosition(at: now) ?? payload.waveformPosition(at: now),
                    currentMarkerWidth: pulseWindow?.markerWidthFraction ?? 0,
                    waveformStartDate: pulseWindow?.startDate ?? payload.waveformStartDate,
                    waveformEndDate: pulseWindow?.endDate ?? payload.waveformEndDate,
                    pulseCycleStartDate: payload.pulseCycleStartDate,
                    pulseCycleEndDate: payload.pulseCycleEndDate,
                    pulseRulerMode: pulseWindow == nil ? .cycle : .megaWindow,
                    pulseWindowKilosarosRange: pulseWindow?.rangeKilosaros ?? 8
                )
                .frame(maxWidth: .infinity)
                .frame(height: 68)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .foregroundStyle(.white)
    }

    private func actionURL(for threadID: String) -> URL? {
        if threadID == ThreadTrackingSharedStore.activityLoggingID {
            return URL(string: "exeligmos://activity/stop")
        }
        return URL(string: "exeligmos://record/\(threadID)")
    }
}

private struct LiveTrackingGlyphView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>
    let size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            WidgetOctalGlyph(
                value: payload.glyph,
                depth: context.attributes.harmonicDepth,
                color: Color(hexString: payload.rarityColorHex),
                secondaryColor: payload.raritySecondaryColorHex.map(Color.init(hexString:))
            )
            .frame(width: payload.isActivityLogging ? max(size, 68) : size, height: payload.isActivityLogging ? max(size, 68) : size)
            .offset(x: 4, y: 4)
        }
    }
}

private struct LiveTrackingCenterView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            let color = Color(hexString: payload.rarityColorHex)
            let signature = payload.waveSignature(at: timeline.date)

            VStack(alignment: .leading, spacing: 3) {
                Text(payload.displayEventName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(signature.type.emoji)
                    Text(signature.label)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                HStack(spacing: 5) {
                    Text(payload.energyText(at: timeline.date))
                    Text(payload.momentumText(at: timeline.date))
                    if !payload.isActivityLogging {
                        WidgetAuxiliaryGlyphsView(payload: payload, date: timeline.date, size: 24)
                    }
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
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
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            WidgetRarityGlyphIcon(
                rawValue: payload.rarityRawValue,
                harmonicDepth: context.attributes.harmonicDepth,
                color: Color(hexString: payload.rarityColorHex),
                size: 18
            )
                .offset(x: -4, y: 3)
        }
    }
}

private struct LiveTrackingWaveTimerView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            let color = Color(hexString: payload.rarityColorHex)
            let pulseWindow = WidgetPulseWindow(payload: payload, at: timeline.date)

            VStack(alignment: .leading, spacing: 5) {
                if !payload.isActivityLogging {
                    WidgetWaveformSegmentView(
                        samples: payload.waveformSamples ?? [],
                        samplePositions: payload.waveformSamplePositions ?? [],
                        spikeMarkers: payload.waveformSpikeMarkers ?? [],
                        color: color,
                        currentPosition: pulseWindow?.discretePosition(at: timeline.date) ?? payload.waveformPosition(at: timeline.date),
                        currentMarkerWidth: pulseWindow?.markerWidthFraction ?? 0,
                        waveformStartDate: pulseWindow?.startDate ?? payload.waveformStartDate,
                        waveformEndDate: pulseWindow?.endDate ?? payload.waveformEndDate,
                        pulseCycleStartDate: payload.pulseCycleStartDate,
                        pulseCycleEndDate: payload.pulseCycleEndDate,
                        pulseRulerMode: pulseWindow == nil ? .cycle : .megaWindow,
                        pulseWindowKilosarosRange: pulseWindow?.rangeKilosaros ?? 8
                    )
                    .frame(height: 52)
                }
                HStack {
                    LiveTrackingTimerView(context: context, compact: false)
                    Spacer(minLength: 4)
                    WidgetAuxiliaryGlyphsView(payload: payload, date: timeline.date, size: 22)
                }
            }
        }
    }
}

private struct LiveTrackingTimerView: View {
    let context: ActivityViewContext<ThreadTrackingAttributes>
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { timeline in
            let payload = context.state.displayPayload(at: timeline.date)
            VStack(alignment: .leading, spacing: compact ? 0 : 6) {
                Group {
                    TrackingCountdownText(
                        payload: payload,
                        now: timeline.date,
                        compact: compact,
                        recordURL: actionURL(for: context.attributes.threadID)
                    )
                }
                .font(compact ? .caption2.weight(.semibold).monospacedDigit() : .title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color(hexString: payload.rarityColorHex))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionURL(for threadID: String) -> URL? {
        if threadID == ThreadTrackingSharedStore.activityLoggingID {
            return URL(string: "exeligmos://activity/stop")
        }
        return URL(string: "exeligmos://record/\(threadID)")
    }
}
