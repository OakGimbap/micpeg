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
//
// The values arrive already scaled: `InputTest` converts RMS to a bar height once per sample,
// where the same number also decides whether the window says no sound is arriving. Doing it
// here instead meant a `log10f` per bar per frame — 1920 a second — and two constants that
// could disagree about where silence is.

import SwiftUI

// `@MainActor` for the reason MainWindow gives.
@MainActor
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
            let levels = test.levels
            guard !levels.isEmpty else { return }

            if reduceMotion {
                // A single bar at the current level. No scrolling history to follow.
                let filled = CGRect(x: 0, y: 0,
                                    width: size.width * CGFloat(levels[levels.count - 1]),
                                    height: size.height)
                context.fill(Path(roundedRect: filled, cornerRadius: radius), with: .style(.tint))
                return
            }

            // One Path and one fill for the whole meter rather than 64 of each, 30 times a
            // second.
            let slot = size.width / CGFloat(levels.count)
            let barWidth = max(1, slot - 1)
            let corner = CGSize(width: barWidth / 2, height: barWidth / 2)
            var bars = Path()
            for (index, level) in levels.enumerated() {
                let height = max(1, size.height * CGFloat(level))
                bars.addRoundedRect(in: CGRect(x: CGFloat(index) * slot,
                                               y: (size.height - height) / 2,
                                               width: barWidth,
                                               height: height),
                                    cornerSize: corner)
            }
            context.fill(bars, with: .style(.tint))
        }
        .frame(height: 28)
        // Decorative: the sentence beside it says everything this shows.
        .accessibilityHidden(true)
    }
}
