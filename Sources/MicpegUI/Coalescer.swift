// One callback per burst.
//
// Every wait in this target for something to stop moving needs it, and for the same reason:
// the events arrive in clusters. A revert moves the default input twice about 400 ms apart —
// the daemon's 300 ms debounce and then its re-verify — and the daemon can write `state.json`
// twice in as long. Redrawing for each is noise, and restarting the audio engine for each tears
// down the one just started.
//
// It was written three times, identically apart from the delay, which put the hop to the main
// actor and the cancel-before-reschedule ordering in three places. They belong to the class of
// bug this project keeps finding: a listener that is alive while the redraw silently stops.

import Foundation

final class Coalescer {
    private let delay: TimeInterval
    private let onFire: @MainActor () -> Void
    private var pending: DispatchWorkItem?

    /// `onFire` runs on the main queue. `pending` has no lock: each owner calls `schedule()`
    /// from one serial queue of its own — a HAL callback queue, a file watch's queue, the main
    /// actor — and `cancel()` from there or from its deinit, when nothing else can reach it.
    init(delay: TimeInterval, onFire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.onFire = onFire
    }

    func schedule() {
        pending?.cancel()
        // Straight onto the main queue. It used to wait on a queue of its own and then hop to
        // the main actor through a Task: two queues and an allocation to arrive where this
        // arrives directly.
        let work = DispatchWorkItem { [onFire] in
            MainActor.assumeIsolated { onFire() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
