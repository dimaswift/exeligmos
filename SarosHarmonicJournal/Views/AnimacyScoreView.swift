import SwiftUI

struct AnimacyScoreView: View {
    let result: AnimacyResult?

    private var score: Double {
        Double(result?.score ?? 0)
    }

    private var confidence: Double {
        Double(result?.confidence ?? 0)
    }

    private var tint: Color {
        Self.tintColor(for: score)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(height: max(8, 72 * score))
            }
            .frame(width: 14, height: 72)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }

            Text("\(Int((score * 100).rounded()))")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())

            Circle()
                .fill(.white.opacity(0.18))
                .overlay {
                    Circle()
                        .trim(from: 0, to: confidence)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.black.opacity(0.48), in: Capsule())
        .opacity(result == nil ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animacy score")
        .accessibilityValue("\(Int((score * 100).rounded())) percent")
    }

    static func tintColor(for score: Double) -> Color {
        let clamped = min(max(score, 0), 1)
        if clamped < 0.5 {
            let t = clamped / 0.5
            return Color(
                red: 1,
                green: 0.08 + 0.76 * t,
                blue: 0.04
            )
        }

        let t = (clamped - 0.5) / 0.5
        return Color(
            red: 1 - 0.88 * t,
            green: 0.84,
            blue: 0.04 + 0.22 * t
        )
    }
}
