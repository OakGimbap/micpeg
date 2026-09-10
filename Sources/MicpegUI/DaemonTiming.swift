// The one measured fact three parts of the window were each re-deriving.
//
// A revert moves the default input **twice**, roughly 400 ms apart: the daemon's 300 ms
// debounce, then its re-verify. Everything in the app that waits for the audio system to stop
// moving is waiting for that, and three files had each written the sentence out and then
// picked their own number — 0.5 s for the device watch, 0.15 s for the file watch, 1.0 s for
// restarting the audio engine. The 0.15 s one could not merge the pair its own comment said it
// existed to merge.
//
// docs/design.md's tuning constants stay in the daemon's config and out of the window
// (app-ui.md forbids showing them). Naming the interval the window has to *wait out* is a
// different thing, and it belongs in one place.

import Foundation

enum DaemonTiming {
    /// How long after the first move the daemon may still move the default input again.
    /// 300 ms debounce + re-verify, measured; rounded up.
    static let settle: TimeInterval = 0.5

    /// Long enough that a burst has finished, short enough that the window does not feel
    /// stale. One settle interval covers the pair; the small extra covers the daemon writing
    /// `state.json` after the second move.
    static let coalesce: TimeInterval = settle + 0.2

    /// Restarting `AVAudioEngine` is expensive and a device change can produce several
    /// configuration-change notifications, so this waits out two settles rather than one.
    static let engineRestart: TimeInterval = settle * 2
}
