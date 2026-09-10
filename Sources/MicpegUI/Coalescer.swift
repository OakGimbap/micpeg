// One callback per burst.
//
// Both watchers in this target need it and for the same reason: the events they hear arrive in
// clusters. A revert moves the default input twice about 400 ms apart — the daemon's 300 ms
// debounce and then its re-verify — and the daemon can write `state.json` twice in as long.
// Redrawing for each is noise.
//
// It was written twice, identically apart from the delay, which put the hop to the main actor
// and the cancel-before-reschedule ordering in two places. Both belong to the class of bug
// this project keeps finding: a listener that is alive while the redraw silently stops.

import Foundation

final class Coalescer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let onFire: @MainActor () -> Void
    private var pending: DispatchWorkItem?

    /// `queue` is the caller's own serial queue, so `pending` is only ever touched there.
    init(delay: TimeInterval, queue: DispatchQueue, onFire: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.queue = queue
        self.onFire = onFire
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [onFire] in
            Task { @MainActor in onFire() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
