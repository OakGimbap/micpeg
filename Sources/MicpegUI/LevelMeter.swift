// The only custom-drawn element in the app, and therefore the only place the native feel can
// break.
//
// app-ui.md's calibration point is System Settings → Sound → Input's own level display: this
// should look that plain. So the restraint here is deliberate and each rule is from that
// document — the accent colour or a semantic colour and nothing else, no gradients or glows,
// a corner radius matched to the surrounding container, and a static level when Reduce Motion
// is on.
//
// It is also decorative. Assistive technology gets nothing from a moving bar, so the meter is
// hidden from it and the adjacent sentence carries the information instead. That is the reason
// the silence hint is a sentence rather than the bar turning a colour.

import SwiftUI

public struct LevelMeter: View {
    private let test: InputTest
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(test: InputTest) { self.test = test }

    public var body: some View {
        Canvas { context, size in
            let radius: CGFloat = 3
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                with: .color(.secondary.opacity(0.15)))

            guard test.isRunning else { return }

            if reduceMotion {
                // A single bar at the current level. No scrolling history to follow.
                let level = CGFloat(normalize(test.levels.last ?? 0))
                let filled = CGRect(x: 0, y: 0, width: size.width * level, height: size.height)
                context.fill(Path(roundedRect: filled, cornerRadius: radius), with: .style(.tint))
                return
            }

            let count = test.levels.count
            guard count > 0 else { return }
            let slot = size.width / CGFloat(count)
            let barWidth = max(1, slot - 1)
            for (index, value) in test.levels.enumerated() {
                let height = max(1, size.height * CGFloat(normalize(value)))
                let rect = CGRect(x: CGFloat(index) * slot,
                                  y: (size.height - height) / 2,
                                  width: barWidth,
                                  height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .style(.tint))
            }
        }
        .frame(height: 28)
        // Decorative: the sentence beside it says everything this shows.
        .accessibilityHidden(true)
    }

    /// RMS is tiny for ordinary sound — measured on this hardware, a quiet room reads 0.0017
    /// and speech an order of magnitude more — so a linear bar would sit flat against the
    /// bottom and read as "nothing is reaching the microphone", the exact wrong answer for a
    /// test whose job is to tell that case apart from a working one.
    ///
    /// A cube root was the first attempt and put a silent room a fifth of the way up the bar.
    /// This is the ordinary decibel mapping with a -60 dBFS floor instead: room noise lands
    /// near the bottom where it belongs, speech occupies the middle, and the curve is one
    /// anybody who has seen an audio meter already knows how to read.
    private func normalize(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(min(max(rms, 1e-7), 1))
        return min(1, max(0, (db + 60) / 60))
    }
}
