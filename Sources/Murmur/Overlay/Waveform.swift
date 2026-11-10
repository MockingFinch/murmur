import SwiftUI

/// The voice, drawn as bars. They rise with loudness (fast attack, slow
/// release), tallest in the middle, each with its own small wobble so it
/// reads as a voice rather than a meter. Silent, they breathe; settling,
/// they turn into a slow travelling wave.
struct Waveform: View {
    let model: HUDModel
    let settling: Bool
    @State private var state = WaveState()

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { gc, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let level = state.step(to: settling ? 0 : Double(model.level), at: t)
                let bars = max(6, Int(size.width / 6))
                let barWidth: CGFloat = 3
                let gap = (size.width - CGFloat(bars) * barWidth) / CGFloat(max(1, bars - 1))
                for i in 0 ..< bars {
                    let x = (Double(i) + 0.5) / Double(bars)
                    let envelope = pow(sin(.pi * x), 0.85)
                    var h: Double
                    if settling {
                        h = 0.16 + 0.42 * envelope * (0.5 + 0.5 * sin(t * 6.5 - Double(i) * 0.7))
                    } else {
                        let wobble = 0.5 + 0.5 * sin(t * 7.3 + Double(i) * 0.62) * cos(t * 3.1 - Double(i) * 0.31)
                        let rest = 0.12 + 0.07 * (0.5 + 0.5 * sin(t * 2.4 + Double(i) * 0.45))
                        h = rest + (0.98 - rest) * level * envelope * (0.42 + 0.58 * wobble)
                    }
                    let height = max(barWidth, CGFloat(h) * size.height)
                    let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                    gc.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(.white.opacity(0.5 + 0.48 * envelope)))
                }
            }
        }
    }
}

/// The level actually drawn, eased toward the measured one.
final class WaveState {
    private var shown = 0.0
    private var last = 0.0

    func step(to target: Double, at time: Double) -> Double {
        let dt = last == 0 ? 0.016 : min(0.05, max(0, time - last))
        last = time
        let rate = target > shown ? 22.0 : 5.0
        shown += (target - shown) * (1 - exp(-rate * dt))
        return shown
    }
}
