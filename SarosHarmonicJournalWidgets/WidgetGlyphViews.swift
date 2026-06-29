import SwiftUI

#if canImport(ActivityKit)
import ActivityKit
#endif

struct TrackingDisplayPayload {
    let saros: Int?
    let eventName: String?
    let energyPercent: Double?
    let momentum: Double?
    let waveDirectionRawValue: String?
    let waveformSamples: [Double]?
    let waveformSamplePositions: [Double]?
    let waveformSpikeMarkers: [TrackingWaveformSpikeMarker]?
    let waveformStartDate: Date?
    let waveformEndDate: Date?
    let glyph: String
    let rarityRawValue: String
    let rarityTitle: String
    let rarityOrderLabel: String
    let raritySymbolName: String
    let rarityColorHex: String
    let raritySecondaryColorHex: String?
    let flipDate: Date
    let isFlipWindow: Bool
    let pulseSaros: Int?
    let pulseCycleStartDate: Date?
    let pulseCycleEndDate: Date?
    let moonSynodicStartDate: Date?
    let moonSynodicEndDate: Date?
    let moonAnomalisticStartDate: Date?
    let moonAnomalisticEndDate: Date?
    let moonDraconicStartDate: Date?
    let moonDraconicEndDate: Date?
}

struct TrackingCountdownText: View {
    let payload: TrackingDisplayPayload
    let now: Date
    var compact: Bool
    var recordURL: URL?

    var body: some View {
        if payload.isFlipWindow {
            if let recordURL {
                Link(destination: recordURL) {
                    recLabel
                }
            } else {
                recLabel
            }
        } else if payload.flipDate > now {
            Text(timerInterval: now...payload.flipDate, countsDown: true)
        } else {
            if let recordURL {
                Link(destination: recordURL) {
                    recLabel
                }
            } else {
                recLabel
            }
        }
    }

    private var recLabel: some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: "record.circle.fill")
            Text("Rec")
        }
        .font(compact ? .caption2.weight(.bold) : .callout.weight(.bold))
        .padding(.horizontal, compact ? 5 : 9)
        .padding(.vertical, compact ? 2 : 4)
        .background(.white.opacity(0.16), in: Capsule())
    }
}

extension ThreadTrackingSnapshot {
    func displayPayload(at now: Date) -> TrackingDisplayPayload {
        let shouldShowNext = now >= flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay)

        if shouldShowNext,
           let nextGlyph,
           let nextRarityTitle,
           let nextRarityOrderLabel,
           let nextRaritySymbolName,
           let nextRarityColorHex,
           let nextFlipDate {
            return TrackingDisplayPayload(
                saros: saros,
                eventName: nextRarityTitle,
                energyPercent: energyPercent,
                momentum: momentum,
                waveDirectionRawValue: waveDirectionRawValue,
                waveformSamples: waveformSamples,
                waveformSamplePositions: waveformSamplePositions,
                waveformSpikeMarkers: waveformSpikeMarkers,
                waveformStartDate: waveformStartDate,
                waveformEndDate: waveformEndDate,
                glyph: nextGlyph,
                rarityRawValue: nextRarityRawValue ?? rarityRawValue,
                rarityTitle: nextRarityTitle,
                rarityOrderLabel: nextRarityOrderLabel,
                raritySymbolName: nextRaritySymbolName,
                rarityColorHex: nextRarityColorHex,
                raritySecondaryColorHex: nextRaritySecondaryColorHex,
                flipDate: nextFlipDate,
                isFlipWindow: false,
                pulseSaros: pulseSaros,
                pulseCycleStartDate: pulseCycleStartDate,
                pulseCycleEndDate: pulseCycleEndDate,
                moonSynodicStartDate: moonSynodicStartDate,
                moonSynodicEndDate: moonSynodicEndDate,
                moonAnomalisticStartDate: moonAnomalisticStartDate,
                moonAnomalisticEndDate: moonAnomalisticEndDate,
                moonDraconicStartDate: moonDraconicStartDate,
                moonDraconicEndDate: moonDraconicEndDate
            )
        }

        return TrackingDisplayPayload(
            saros: saros,
            eventName: eventName,
            energyPercent: energyPercent,
            momentum: momentum,
            waveDirectionRawValue: waveDirectionRawValue,
            waveformSamples: waveformSamples,
            waveformSamplePositions: waveformSamplePositions,
            waveformSpikeMarkers: waveformSpikeMarkers,
            waveformStartDate: waveformStartDate,
            waveformEndDate: waveformEndDate,
            glyph: glyph,
            rarityRawValue: rarityRawValue,
            rarityTitle: rarityTitle,
            rarityOrderLabel: rarityOrderLabel,
            raritySymbolName: raritySymbolName,
            rarityColorHex: rarityColorHex,
            raritySecondaryColorHex: raritySecondaryColorHex,
            flipDate: flipDate,
            isFlipWindow: now >= flipDate,
            pulseSaros: pulseSaros,
            pulseCycleStartDate: pulseCycleStartDate,
            pulseCycleEndDate: pulseCycleEndDate,
            moonSynodicStartDate: moonSynodicStartDate,
            moonSynodicEndDate: moonSynodicEndDate,
            moonAnomalisticStartDate: moonAnomalisticStartDate,
            moonAnomalisticEndDate: moonAnomalisticEndDate,
            moonDraconicStartDate: moonDraconicStartDate,
            moonDraconicEndDate: moonDraconicEndDate
        )
    }

}

#if canImport(ActivityKit)
extension ThreadTrackingAttributes.ContentState {
    func displayPayload(at now: Date) -> TrackingDisplayPayload {
        let shouldShowNext = now >= flipDate.addingTimeInterval(ThreadTrackingSharedStore.flipRolloverDelay)

        if shouldShowNext,
           let nextGlyph,
           let nextRarityTitle,
           let nextRarityOrderLabel,
           let nextRaritySymbolName,
           let nextRarityColorHex,
           let nextFlipDate {
            return TrackingDisplayPayload(
                saros: saros,
                eventName: nextRarityTitle,
                energyPercent: energyPercent,
                momentum: momentum,
                waveDirectionRawValue: waveDirectionRawValue,
                waveformSamples: waveformSamples,
                waveformSamplePositions: waveformSamplePositions,
                waveformSpikeMarkers: waveformSpikeMarkers,
                waveformStartDate: waveformStartDate,
                waveformEndDate: waveformEndDate,
                glyph: nextGlyph,
                rarityRawValue: nextRarityRawValue ?? rarityRawValue,
                rarityTitle: nextRarityTitle,
                rarityOrderLabel: nextRarityOrderLabel,
                raritySymbolName: nextRaritySymbolName,
                rarityColorHex: nextRarityColorHex,
                raritySecondaryColorHex: nextRaritySecondaryColorHex,
                flipDate: nextFlipDate,
                isFlipWindow: false,
                pulseSaros: pulseSaros,
                pulseCycleStartDate: pulseCycleStartDate,
                pulseCycleEndDate: pulseCycleEndDate,
                moonSynodicStartDate: moonSynodicStartDate,
                moonSynodicEndDate: moonSynodicEndDate,
                moonAnomalisticStartDate: moonAnomalisticStartDate,
                moonAnomalisticEndDate: moonAnomalisticEndDate,
                moonDraconicStartDate: moonDraconicStartDate,
                moonDraconicEndDate: moonDraconicEndDate
            )
        }

        return TrackingDisplayPayload(
            saros: saros,
            eventName: eventName,
            energyPercent: energyPercent,
            momentum: momentum,
            waveDirectionRawValue: waveDirectionRawValue,
            waveformSamples: waveformSamples,
            waveformSamplePositions: waveformSamplePositions,
            waveformSpikeMarkers: waveformSpikeMarkers,
            waveformStartDate: waveformStartDate,
            waveformEndDate: waveformEndDate,
            glyph: glyph,
            rarityRawValue: rarityRawValue,
            rarityTitle: rarityTitle,
            rarityOrderLabel: rarityOrderLabel,
            raritySymbolName: raritySymbolName,
            rarityColorHex: rarityColorHex,
            raritySecondaryColorHex: raritySecondaryColorHex,
            flipDate: flipDate,
            isFlipWindow: now >= flipDate,
            pulseSaros: pulseSaros,
            pulseCycleStartDate: pulseCycleStartDate,
            pulseCycleEndDate: pulseCycleEndDate,
            moonSynodicStartDate: moonSynodicStartDate,
            moonSynodicEndDate: moonSynodicEndDate,
            moonAnomalisticStartDate: moonAnomalisticStartDate,
            moonAnomalisticEndDate: moonAnomalisticEndDate,
            moonDraconicStartDate: moonDraconicStartDate,
            moonDraconicEndDate: moonDraconicEndDate
        )
    }

}
#endif

struct WidgetWaveformSegmentView: View {
    let samples: [Double]
    var samplePositions: [Double] = []
    var spikeMarkers: [TrackingWaveformSpikeMarker] = []
    let color: Color
    var showsCurrentMarker = true
    var currentPosition: Double = 0.5
    var waveformStartDate: Date?
    var waveformEndDate: Date?
    var pulseCycleStartDate: Date?
    var pulseCycleEndDate: Date?

    var body: some View {
        canvas(currentPosition: currentPosition)
        .accessibilityHidden(true)
    }

    private func canvas(currentPosition: Double) -> some View {
        Canvas { context, size in
            guard samples.count > 1, size.width > 2, size.height > 2 else { return }

            let clamped = samples.map { min(max($0, 0), 1) }
            let markerMax = spikeMarkers.map { min(max($0.energy, 0), 1) }.max() ?? 0
            let localMax = max(clamped.max() ?? 0, markerMax, 0.08)
            let visualScale = 1.0 / localMax
            let visualValue: (Double) -> Double = { value in
                min(max(value, 0) * visualScale, 1)
            }
            let positions = resolvedSamplePositions(count: clamped.count)
            let baselineY = size.height
            let extendedWidth = size.width + 160
            let xOffset: CGFloat = -80
            var line = Path()
            var fill = Path()

            for index in clamped.indices {
                let x = xOffset + CGFloat(positions[index]) * extendedWidth
                let y = baselineY - CGFloat(visualValue(clamped[index])) * (size.height - 5)
                let point = CGPoint(x: x, y: y)
                if index == clamped.startIndex {
                    line.move(to: point)
                    fill.move(to: CGPoint(x: x, y: baselineY))
                    fill.addLine(to: point)
                } else {
                    line.addLine(to: point)
                    fill.addLine(to: point)
                }
            }

            fill.addLine(to: CGPoint(x: size.width + 80, y: baselineY))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.24)))
            context.stroke(line, with: .color(color.opacity(0.92)), lineWidth: 1.4)

            for marker in spikeMarkers {
                let x = xOffset + CGFloat(min(max(marker.position, 0), 1)) * extendedWidth
                let y = baselineY - CGFloat(visualValue(marker.energy)) * (size.height - 5)
                let dotRect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dotRect), with: .color(Color(hexString: marker.colorHex)))
                context.stroke(Path(ellipseIn: dotRect.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.45)), lineWidth: 1)
            }

            drawPulseTicks(
                in: context,
                size: size,
                extendedWidth: extendedWidth,
                xOffset: xOffset
            )

            if showsCurrentMarker {
                let markerX = xOffset + CGFloat(min(max(currentPosition, 0), 1)) * extendedWidth
                var marker = Path()
                marker.move(to: CGPoint(x: markerX, y: 0))
                marker.addLine(to: CGPoint(x: markerX, y: size.height))
                context.stroke(marker, with: .color(.green.opacity(0.72)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
        }
    }

    private func drawPulseTicks(
        in context: GraphicsContext,
        size: CGSize,
        extendedWidth: CGFloat,
        xOffset: CGFloat
    ) {
        guard let waveformStartDate,
              let waveformEndDate,
              waveformEndDate > waveformStartDate,
              let pulseCycleStartDate,
              let pulseCycleEndDate,
              pulseCycleEndDate > pulseCycleStartDate
        else {
            return
        }

        let cycleDuration = pulseCycleEndDate.timeIntervalSince(pulseCycleStartDate)
        let waveformDuration = waveformEndDate.timeIntervalSince(waveformStartDate)
        let pulseRolloverDuration = cycleDuration / 512
        let tickSpecs: [(divisions: Double, color: Color, height: CGFloat, lineWidth: CGFloat)] = [
            (512, .blue.opacity(0.72), min(size.height * 0.48, 22), 0.6),
            (64, .purple.opacity(0.84), min(size.height * 0.66, 30), 0.9),
            (8, .yellow.opacity(0.95), min(size.height * 0.86, 38), 1.2),
            (1, .red.opacity(0.95), min(size.height * 0.96, 44), 1.4)
        ]

        for spec in tickSpecs {
            let step = pulseRolloverDuration / spec.divisions
            guard step > 0, waveformDuration / step <= 240 else { continue }
            var index = ceil(waveformStartDate.timeIntervalSince(pulseCycleStartDate) / step)
            var rendered = 0

            while rendered < 240 {
                let tickDate = pulseCycleStartDate.addingTimeInterval(index * step)
                if tickDate > waveformEndDate { break }
                if tickDate >= waveformStartDate {
                    let position = tickDate.timeIntervalSince(waveformStartDate) / waveformDuration
                    let x = xOffset + CGFloat(position) * extendedWidth
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - spec.height))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(spec.color), lineWidth: spec.lineWidth)
                    rendered += 1
                }
                index += 1
            }
        }
    }

    private func resolvedSamplePositions(count: Int) -> [Double] {
        guard samplePositions.count == count else {
            guard count > 1 else { return [0] }
            return (0..<count).map { Double($0) / Double(count - 1) }
        }

        return samplePositions.map { min(max($0, 0), 1) }
    }

}

extension TrackingDisplayPayload {
    var displayEventName: String {
        eventName?.nilIfBlank ?? rarityTitle
    }

    func secondaryEventDescription(at date: Date) -> String {
        let energy = sampledEnergy(at: date) ?? energyPercent ?? 0
        let momentum = sampledMomentum(at: date) ?? momentum ?? 0
        let magnitude = abs(momentum)

        if energy >= 0.88 {
            let modifier = magnitude >= 0.72 ? "sharp" : "dull"
            return "\(modifier) peak"
        }
        if energy <= 0.06 {
            let modifier = magnitude >= 0.72 ? "narrow" : "giant"
            return "\(modifier) valley"
        }

        let pace = magnitude >= 0.45 ? "rapid" : "slow"
        if momentum > 0.02 {
            return "\(pace) ascent"
        }
        if momentum < -0.02 {
            return "\(pace) descent"
        }
        return "flat"
    }

    func energyText(at date: Date) -> String {
        let energy = sampledEnergy(at: date) ?? energyPercent
        guard let energy else { return "E --" }
        return "E \(Int((min(max(energy, 0), 1) * 100).rounded()))%"
    }

    func momentumText(at date: Date) -> String {
        let value = sampledMomentum(at: date) ?? momentum
        guard let value else { return "M --" }
        let percent = Int((min(max(value, -1), 1) * 100).rounded())
        return percent > 0 ? "M +\(percent)%" : "M \(percent)%"
    }

    func waveformPosition(at date: Date) -> Double {
        guard let waveformStartDate,
              let waveformEndDate,
              waveformEndDate > waveformStartDate
        else {
            return 0.5
        }
        return min(max(date.timeIntervalSince(waveformStartDate) / waveformEndDate.timeIntervalSince(waveformStartDate), 0), 1)
    }

    func pulseGlyph(at date: Date) -> String? {
        guard let pulseCycleStartDate,
              let pulseCycleEndDate,
              pulseCycleEndDate > pulseCycleStartDate
        else {
            return nil
        }

        let duration = pulseCycleEndDate.timeIntervalSince(pulseCycleStartDate)
        let phase = date.timeIntervalSince(pulseCycleStartDate) / duration
        let localPhase = Self.positiveFraction(phase * 512)
        let binCount = 262_144
        let bin = min(max(Int(floor(localPhase * Double(binCount))), 0), binCount - 1)
        return String(bin, radix: 8).leftPadded(toLength: 6, withPad: "0")
    }

    func pulseColor(at date: Date) -> Color {
        guard let glyph = pulseGlyph(at: date) else { return .white.opacity(0.82) }
        let trailingZeroes = glyph.reversed().prefix { $0 == "0" }.count
        switch trailingZeroes {
        case 5...: return .red
        case 4: return .yellow
        case 3: return .purple
        case 2: return .blue
        default: return .white
        }
    }

    func moonGlyph(at date: Date) -> String? {
        guard let synodic = moonDigit(at: date, start: moonSynodicStartDate, end: moonSynodicEndDate),
              let anomalistic = moonDigit(at: date, start: moonAnomalisticStartDate, end: moonAnomalisticEndDate),
              let draconic = moonDigit(at: date, start: moonDraconicStartDate, end: moonDraconicEndDate)
        else {
            return nil
        }

        return "\(synodic)\(anomalistic)\(draconic)"
    }

    func moonColor(at date: Date) -> Color {
        guard let moonSynodicStartDate,
              let moonSynodicEndDate,
              moonSynodicEndDate > moonSynodicStartDate
        else {
            return .white.opacity(0.82)
        }

        let phase = Self.positiveFraction(
            date.timeIntervalSince(moonSynodicStartDate)
                / moonSynodicEndDate.timeIntervalSince(moonSynodicStartDate)
        )
        let bin = min(max(Int(floor(phase * 512)), 0), 511)
        let address = String(bin, radix: 8).leftPadded(toLength: 3, withPad: "0")

        if address == "000" || address == "777" {
            return .purple
        }

        let leadingZeroes = address.prefix { $0 == "0" }.count
        let leadingSevens = address.prefix { $0 == "7" }.count
        switch max(leadingZeroes, leadingSevens) {
        case 2...: return .blue
        case 1: return .gray
        default: return .white
        }
    }

    private func sampledEnergy(at date: Date) -> Double? {
        guard let waveformSamples, waveformSamples.count > 1 else { return nil }
        let position = waveformPosition(at: date)
        guard let pair = samplePair(at: position, sampleCount: waveformSamples.count) else { return nil }
        return waveformSamples[pair.lower]
            + (waveformSamples[pair.upper] - waveformSamples[pair.lower]) * pair.fraction
    }

    private func sampledMomentum(at date: Date) -> Double? {
        guard let waveformSamples, waveformSamples.count > 2 else { return nil }
        let position = waveformPosition(at: date)
        let positions = resolvedPositions(sampleCount: waveformSamples.count)
        let center = positions.enumerated()
            .min { abs($0.element - position) < abs($1.element - position) }?
            .offset ?? 1
        let lower = max(center - 1, 0)
        let upper = min(center + 1, waveformSamples.count - 1)
        let dx = max(positions[upper] - positions[lower], 0.000_001)
        let dy = waveformSamples[upper] - waveformSamples[lower]
        let gradient = dy / dx
        let angle = atan(abs(gradient))
        let flatAngle = 5.0 * Double.pi / 180.0
        let verticalAngle = 88.0 * Double.pi / 180.0
        let normalized = min(max((angle - flatAngle) / (verticalAngle - flatAngle), 0), 1)
        return normalized * (gradient >= 0 ? 1 : -1)
    }

    private func samplePair(
        at position: Double,
        sampleCount: Int
    ) -> (lower: Int, upper: Int, fraction: Double)? {
        let positions = resolvedPositions(sampleCount: sampleCount)
        guard positions.count == sampleCount, sampleCount > 1 else { return nil }
        let clamped = min(max(position, 0), 1)

        if clamped <= positions[0] {
            return (0, 1, 0)
        }

        for index in 0..<(sampleCount - 1) {
            let left = positions[index]
            let right = positions[index + 1]
            guard clamped <= right || index == sampleCount - 2 else { continue }
            let fraction = (clamped - left) / max(right - left, 0.000_001)
            return (index, index + 1, min(max(fraction, 0), 1))
        }

        return (sampleCount - 2, sampleCount - 1, 1)
    }

    private func resolvedPositions(sampleCount: Int) -> [Double] {
        guard waveformSamplePositions?.count == sampleCount,
              let waveformSamplePositions
        else {
            guard sampleCount > 1 else { return [0] }
            return (0..<sampleCount).map { Double($0) / Double(sampleCount - 1) }
        }

        return waveformSamplePositions.map { min(max($0, 0), 1) }
    }

    private func moonDigit(at date: Date, start: Date?, end: Date?) -> Int? {
        guard let start,
              let end,
              end > start
        else {
            return nil
        }

        let phase = Self.positiveFraction(date.timeIntervalSince(start) / end.timeIntervalSince(start))
        return min(max(Int(floor(phase * 8)), 0), 7)
    }

    private static func positiveFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let fraction = value - floor(value)
        return fraction >= 0 ? fraction : fraction + 1
    }
}

struct WidgetWaveDirectionIcon: View {
    let rawValue: String?
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch rawValue {
        case "ascending": "arrow.up"
        case "descending": "arrow.down"
        default: "minus"
        }
    }

    private var color: Color {
        switch rawValue {
        case "ascending": .green
        case "descending": .red
        default: .white
        }
    }

    private var accessibilityLabel: String {
        switch rawValue {
        case "ascending": "Ascending"
        case "descending": "Descending"
        default: "Flat"
        }
    }
}

struct WidgetAuxiliaryGlyphsView: View {
    let payload: TrackingDisplayPayload
    let date: Date
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            if let pulseGlyph = payload.pulseGlyph(at: date) {
                WidgetOctalGlyph(
                    value: pulseGlyph,
                    depth: 6,
                    color: payload.pulseColor(at: date)
                )
                .frame(width: size, height: size)
                .id("pulse-\(pulseGlyph)")
                .accessibilityLabel("Pulse glyph")
            }

            if let moonGlyph = payload.moonGlyph(at: date) {
                WidgetOctalGlyph(
                    value: moonGlyph,
                    depth: 3,
                    color: payload.moonColor(at: date)
                )
                .frame(width: size, height: size)
                .id("moon-\(moonGlyph)")
                .accessibilityLabel("Lunar glyph")
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func leftPadded(toLength length: Int, withPad pad: Character) -> String {
        guard count < length else { return String(suffix(length)) }
        return String(repeating: String(pad), count: length - count) + self
    }
}

struct WidgetRarityGlyphIcon: View {
    let rawValue: String
    let harmonicDepth: Int
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        if rawValue == "common" {
            EmptyView()
        } else {
            WidgetOctalGlyph(
                value: Self.glyphAddress(rawValue: rawValue, harmonicDepth: harmonicDepth),
                depth: harmonicDepth,
                color: color
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    private static func glyphAddress(rawValue: String, harmonicDepth: Int) -> String {
        let depth = min(max(harmonicDepth, 1), 8)
        let pattern = rarityPattern(rawValue: rawValue)
        let prefixCount = min(pattern.wildcardPrefixCount, depth)
        let suffixLength = max(depth - prefixCount, 0)
        return String(repeating: "0", count: prefixCount)
            + String(repeating: "\(pattern.digit)", count: suffixLength)
    }

    private static func rarityPattern(rawValue: String) -> (wildcardPrefixCount: Int, digit: Int) {
        let parts = rawValue.split(separator: "-", maxSplits: 1).map(String.init)
        let base = parts.first ?? rawValue
        let digit = parts.dropFirst().first.flatMap(Int.init).map { min(max($0, 1), 7) } ?? 7

        switch base {
        case "common":
            return (8, 7)
        case "rare":
            return (3, digit)
        case "epic":
            return (2, digit)
        case "legendary":
            return (1, digit)
        case "mythic", "saros":
            return (0, digit)
        default:
            if base.hasPrefix("saros"),
               let suffix = Int(base.dropFirst(5))
            {
                return (0, suffix == 0 ? 7 : min(max(suffix, 1), 7))
            }
            return (3, 7)
        }
    }
}

struct WidgetOctalGlyph: View {
    let value: String
    let depth: Int
    let color: Color
    var secondaryColor: Color?

    var body: some View {
        let geometry = WidgetOctalGlyphGeometryCache.geometry(for: depth)

        ZStack {
            WidgetOctalGlyphCoreShape(depth: depth)
                .fill(secondaryColor ?? color, style: FillStyle(eoFill: true))

            if secondaryColor != nil {
                ForEach(0..<geometry.digitCount, id: \.self) { socketIndex in
                    WidgetOctalGlyphArmSegmentShape(value: value, depth: depth, socketIndex: socketIndex)
                        .fill(color)
                }
            } else {
                WidgetOctalGlyphArmShape(value: value, depth: depth)
                    .fill(color)
            }
        }
        .aspectRatio(geometry.aspectRatio, contentMode: .fit)
        .accessibilityLabel("Octal glyph")
        .accessibilityValue(geometry.normalizedOctal(value))
    }
}

extension Color {
    init(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(trimmed, radix: 16) else {
            self = .green
            return
        }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}

private struct WidgetOctalGlyphCoreShape: Shape {
    let depth: Int

    func path(in rect: CGRect) -> Path {
        WidgetOctalGlyphGeometryCache.geometry(for: depth).corePath(in: rect)
    }
}

private struct WidgetOctalGlyphArmShape: Shape {
    let value: String
    let depth: Int

    func path(in rect: CGRect) -> Path {
        WidgetOctalGlyphGeometryCache.geometry(for: depth).armPath(for: value, in: rect)
    }
}

private struct WidgetOctalGlyphArmSegmentShape: Shape {
    let value: String
    let depth: Int
    let socketIndex: Int

    func path(in rect: CGRect) -> Path {
        WidgetOctalGlyphGeometryCache.geometry(for: depth).armPath(for: value, socketIndex: socketIndex, in: rect)
    }
}

private enum WidgetOctalGlyphGeometryCache {
    private static let geometries: [Int: WidgetOctalGlyphGeometry] = {
        Dictionary(uniqueKeysWithValues: (1...8).map { ($0, WidgetOctalGlyphGeometry(depth: $0)) })
    }()

    static func geometry(for depth: Int) -> WidgetOctalGlyphGeometry {
        let clampedDepth = min(max(depth, 1), 8)
        return geometries[clampedDepth] ?? WidgetOctalGlyphGeometry(depth: clampedDepth)
    }
}

private struct WidgetOctalGlyphSocket {
    let start: CGPoint
    let end: CGPoint
}

private struct WidgetOctalGlyphSocketFrame {
    let center: CGPoint
    let tangent: CGPoint
    let outward: CGPoint
    let length: CGFloat
}

private struct WidgetOctalGlyphGeometry {
    let digitCount: Int
    let aspectRatio: CGFloat
    private let frameBounds: CGRect
    private let coreTemplatePath: Path
    private let armTemplatePaths: [[Path]]

    init(depth: Int) {
        let digitCount = min(max(depth, 1), 8)
        let sockets = Self.makeSockets(digitCount: digitCount)
        let corePolygon = sockets.flatMap { [$0.start, $0.end] }
        let coreHole = digitCount == 7
            ? Self.defaultCoreHole
            : Self.insetConvexPolygon(corePolygon, thickness: 14)
        let frameBounds = Self.makeFrameBounds(
            corePolygon: corePolygon,
            coreHole: coreHole,
            sockets: sockets,
            digitCount: digitCount
        )

        self.digitCount = digitCount
        self.frameBounds = frameBounds
        self.aspectRatio = frameBounds.width / frameBounds.height
        self.coreTemplatePath = Self.path(for: [corePolygon, coreHole])
        self.armTemplatePaths = (0..<digitCount).map { socketIndex in
            (0...7).map { digit in
                let points = Self.armToWorldPoints(
                    Self.arms[digit] ?? [],
                    socketIndex: socketIndex,
                    sockets: sockets
                )
                return points.count >= 3 ? Self.path(for: [points]) : Path()
            }
        }
    }

    func normalizedOctal(_ value: String) -> String {
        normalizedDigits(value).map(String.init).joined()
    }

    func corePath(in rect: CGRect) -> Path {
        coreTemplatePath.applying(transform(in: rect))
    }

    func armPath(for value: String, in rect: CGRect) -> Path {
        let digits = normalizedDigits(value)
        var path = Path()

        for socketIndex in 0..<digitCount {
            let digit = digits[digitIndex(forSocketIndex: socketIndex)]
            path.addPath(armTemplatePaths[socketIndex][digit])
        }

        return path.applying(transform(in: rect))
    }

    func armPath(for value: String, socketIndex: Int, in rect: CGRect) -> Path {
        guard (0..<digitCount).contains(socketIndex) else { return Path() }
        let digits = normalizedDigits(value)
        let digit = digits[digitIndex(forSocketIndex: socketIndex)]
        return armTemplatePaths[socketIndex][digit].applying(transform(in: rect))
    }

    func digitIndex(forSocketIndex socketIndex: Int) -> Int {
        socketIndex == 0 ? 0 : digitCount - socketIndex
    }

    private func normalizedDigits(_ value: String) -> [Int] {
        var digits: [Int] = []
        digits.reserveCapacity(digitCount)

        for byte in value.utf8 where (48...55).contains(byte) {
            digits.append(Int(byte - 48))
        }

        if digits.count > digitCount {
            digits.removeFirst(digits.count - digitCount)
        }

        if digits.count < digitCount {
            digits.insert(contentsOf: repeatElement(0, count: digitCount - digits.count), at: 0)
        }

        return digits
    }

    private func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / frameBounds.width, rect.height / frameBounds.height)
        let width = frameBounds.width * scale
        let height = frameBounds.height * scale
        let xOffset = rect.midX - width / 2 - frameBounds.minX * scale
        let yOffset = rect.midY - height / 2 - frameBounds.minY * scale

        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: xOffset,
            ty: yOffset
        )
    }

    private static func makeSockets(digitCount: Int) -> [WidgetOctalGlyphSocket] {
        let baseStart = CGPoint(x: -socketWidth / 2, y: -coreRadius)
        let baseEnd = CGPoint(x: socketWidth / 2, y: -coreRadius)
        let rotationStep = 360 / CGFloat(digitCount)

        return (0..<digitCount).map { index in
            let rotation = CGFloat(index) * rotationStep
            return WidgetOctalGlyphSocket(
                start: rotate(baseStart, degrees: rotation),
                end: rotate(baseEnd, degrees: rotation)
            )
        }
    }

    private static func makeFrameBounds(
        corePolygon: [CGPoint],
        coreHole: [CGPoint],
        sockets: [WidgetOctalGlyphSocket],
        digitCount: Int
    ) -> CGRect {
        var points = corePolygon + coreHole
        points.append(contentsOf: sockets.flatMap { [$0.start, $0.end] })

        for socketIndex in 0..<digitCount {
            for arm in arms.values {
                points.append(contentsOf: armToWorldPoints(arm, socketIndex: socketIndex, sockets: sockets))
            }
        }

        let minX = points.map(\.x).min() ?? -90
        let maxX = points.map(\.x).max() ?? 90
        let minY = points.map(\.y).min() ?? -150
        let maxY = points.map(\.y).max() ?? 90
        let padding = gridSize * paddingCells
        let halfWidth = max(gridSize, ceil(max(abs(minX), abs(maxX)) / gridSize) * gridSize + padding)
        let halfHeight = max(gridSize, ceil(max(abs(minY), abs(maxY)) / gridSize) * gridSize + padding)

        return CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)
    }

    private static func path(for polygons: [[CGPoint]]) -> Path {
        var path = Path()

        for polygon in polygons where polygon.count >= 3 {
            guard let first = polygon.first else { continue }

            path.move(to: first)
            for point in polygon.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }

        return path
    }

    private static func armToWorldPoints(
        _ points: [CGPoint],
        socketIndex: Int,
        sockets: [WidgetOctalGlyphSocket]
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }

        let frame = socketFrame(socketIndex, sockets: sockets)
        var aligned = points
        aligned[0] = CGPoint(x: -frame.length / 2, y: 0)
        aligned[aligned.count - 1] = CGPoint(x: frame.length / 2, y: 0)

        return aligned.map { point in
            CGPoint(
                x: frame.center.x + frame.tangent.x * point.x + frame.outward.x * point.y,
                y: frame.center.y + frame.tangent.y * point.x + frame.outward.y * point.y
            )
        }
    }

    private static func socketFrame(
        _ index: Int,
        sockets: [WidgetOctalGlyphSocket]
    ) -> WidgetOctalGlyphSocketFrame {
        let socket = sockets[index]
        let center = midpoint(socket.start, socket.end)
        let dx = socket.end.x - socket.start.x
        let dy = socket.end.y - socket.start.y
        let length = max(hypot(dx, dy), 0.001)
        let tangent = CGPoint(x: dx / length, y: dy / length)
        let centerVector = CGPoint(x: center.x, y: center.y)
        var outward = CGPoint(x: tangent.y, y: -tangent.x)

        if outward.x * centerVector.x + outward.y * centerVector.y < 0 {
            outward = CGPoint(x: -outward.x, y: -outward.y)
        }

        return WidgetOctalGlyphSocketFrame(
            center: center,
            tangent: tangent,
            outward: outward,
            length: length
        )
    }

    private static func insetConvexPolygon(_ points: [CGPoint], thickness: CGFloat) -> [CGPoint] {
        guard points.count >= 3, thickness > 0 else { return points }

        let inwardSign: CGFloat = signedArea(points) >= 0 ? 1 : -1
        let lines = points.enumerated().map { index, point in
            let next = points[(index + 1) % points.count]
            let dx = next.x - point.x
            let dy = next.y - point.y
            let length = max(hypot(dx, dy), 0.001)
            let normal = CGPoint(x: (-dy / length) * inwardSign, y: (dx / length) * inwardSign)

            return (
                point: CGPoint(x: point.x + normal.x * thickness, y: point.y + normal.y * thickness),
                direction: CGPoint(x: dx, y: dy)
            )
        }

        return points.enumerated().map { index, point in
            let previous = lines[(index + lines.count - 1) % lines.count]
            let current = lines[index]
            return intersectLines(
                pointA: previous.point,
                directionA: previous.direction,
                pointB: current.point,
                directionB: current.direction
            ) ?? point
        }
    }

    private static func intersectLines(
        pointA: CGPoint,
        directionA: CGPoint,
        pointB: CGPoint,
        directionB: CGPoint
    ) -> CGPoint? {
        let cross = directionA.x * directionB.y - directionA.y * directionB.x
        guard abs(cross) >= 0.000001 else { return nil }

        let delta = CGPoint(x: pointB.x - pointA.x, y: pointB.y - pointA.y)
        let t = (delta.x * directionB.y - delta.y * directionB.x) / cross
        return CGPoint(x: pointA.x + directionA.x * t, y: pointA.y + directionA.y * t)
    }

    private static func signedArea(_ points: [CGPoint]) -> CGFloat {
        points.enumerated().reduce(CGFloat.zero) { area, item in
            let next = points[(item.offset + 1) % points.count]
            return area + item.element.x * next.y - next.x * item.element.y
        }
    }

    private static func rotate(_ point: CGPoint, degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        return CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
    }

    private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private static let defaultCoreHole: [CGPoint] = [
        CGPoint(x: 27.95, y: 1.45),
        CGPoint(x: 25.81, y: 10.82),
        CGPoint(x: 16.29, y: 22.75),
        CGPoint(x: 7.63, y: 26.92),
        CGPoint(x: -7.63, y: 26.92),
        CGPoint(x: -16.29, y: 22.75),
        CGPoint(x: -25.81, y: 10.82),
        CGPoint(x: -27.95, y: 1.45)
    ]

    private static let socketWidth: CGFloat = 16
    private static let coreRadius: CGFloat = 41.57
    private static let gridSize: CGFloat = 8
    private static let paddingCells: CGFloat = 2

    private static let arms: [Int: [CGPoint]] = [
        0: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: 8, y: 0)
        ],
        1: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -24, y: 27.71),
            CGPoint(x: -16, y: 41.57),
            CGPoint(x: 8, y: 0)
        ],
        2: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -8, y: 96.99),
            CGPoint(x: 0, y: 110.85),
            CGPoint(x: 8, y: 96.99),
            CGPoint(x: 8, y: 0)
        ],
        3: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -40, y: 55.42),
            CGPoint(x: -8, y: 110.85),
            CGPoint(x: 0, y: 96.99),
            CGPoint(x: -24, y: 55.42),
            CGPoint(x: 8, y: 0)
        ],
        4: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: 16, y: 41.57),
            CGPoint(x: 24, y: 27.71),
            CGPoint(x: 8, y: 0)
        ],
        5: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -40, y: 55.42),
            CGPoint(x: 24, y: 55.42),
            CGPoint(x: 32, y: 41.57),
            CGPoint(x: -16, y: 41.57),
            CGPoint(x: 8, y: 0)
        ],
        6: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -8, y: 138.56),
            CGPoint(x: 32, y: 69.28),
            CGPoint(x: 24, y: 55.42),
            CGPoint(x: 8, y: 83.14),
            CGPoint(x: 8, y: 0)
        ],
        7: [
            CGPoint(x: -8, y: 0),
            CGPoint(x: -40, y: 55.42),
            CGPoint(x: 0, y: 124.71),
            CGPoint(x: 32, y: 69.28),
            CGPoint(x: 24, y: 55.42),
            CGPoint(x: 0, y: 96.99),
            CGPoint(x: -24, y: 55.42),
            CGPoint(x: 8, y: 0)
        ]
    ]
}
