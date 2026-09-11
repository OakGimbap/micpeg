// Noticing that the daemon wrote something.
//
// The obvious implementation is wrong, and CLAUDE.md names it as one of this app's silent
// failures: "a state.json watcher that dies on the first atomic write". The daemon writes with
// `Data.write(to:options: .atomic)`, which writes a temporary file and renames it into place.
// A DispatchSource attached to the *file's* descriptor keeps that descriptor open on an inode
// that is no longer at the path — it reports `.rename`/`.delete` once and then never fires
// again, while the window keeps showing whatever it read at launch. It does not crash, and it
// does not log anything.
//
// So for `~/.config/micpeg` this watches the *directory*. A rename into it is a directory
// write, and re-reading from the path picks up whichever inode is there now. Measured — see
// docs/verification.md.
//
// **The log is the opposite case, and gets the opposite watch.** The daemon never replaces it:
// its stderr is opened `O_APPEND` (`redirectStderrToLogIfDiscarded()`) and grows in place, and
// `truncateLogIfLarge()` cuts it with `truncate(2)` — the same inode both ways. So the
// file's own descriptor stays valid, and watching `~/Library/Logs` instead would be
// wrong twice over: a directory reports entries being added and removed, not a file inside it
// growing, and that directory belongs to every program on the machine. The log needs a watch of
// its own because a failed revert writes a log line and nothing else — no state.json — and the
// window's failure banner has to notice it.
//
// If the log is deleted, the daemon keeps writing to the unlinked file and the path stays empty
// until the daemon restarts. The watch polls for the path to reappear; there is nothing more to
// do from here.
//
// The path may not exist at all on a fresh install; the daemon creates both on its first
// write. In that case there is nothing to attach to, so the watcher polls at 1 Hz until the
// path appears and then attaches. It runs only while a window is open, so this costs nothing
// that matters, and it means onboarding sees the config the moment the CLI creates it.

import Foundation

/// Calls `onChange` on the main queue whenever the watched path changes, coalescing bursts.
/// Stops when deinitialised.
public final class PathWatch {
    public enum Kind {
        /// Written by atomic rename, like `~/.config/micpeg`: watch the directory.
        case directory
        /// Appended to in place, like the log: watch the file itself.
        case appendedFile
    }

    private let path: URL
    private let mask: DispatchSource.FileSystemEvent
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.micpeg.app.watch")
    private let coalescer: Coalescer

    public init(_ path: URL, kind: Kind, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        // .write covers a rename into a directory — what an atomic write looks like from there —
        // and a write to a file. .extend is a file growing. .delete and .rename cover the path
        // itself going away, which is the case that has to re-arm rather than go quiet.
        switch kind {
        case .directory:    mask = [.write, .delete, .rename]
        case .appendedFile: mask = [.write, .extend, .delete, .rename]
        }
        self.coalescer = Coalescer(delay: DaemonTiming.coalesce, onFire: onChange)
        queue.async { [weak self] in self?.attachOrPoll() }
    }

    deinit {
        coalescer.cancel()
        // Its cancel handler closes the descriptor: one is only ever opened to make a source.
        source?.cancel()
        pollTimer?.cancel()
    }

    // MARK: - Attaching

    private func attachOrPoll() {
        guard FileManager.default.fileExists(atPath: path.path) else {
            startPolling()
            return
        }
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else {
            startPolling()
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask,
                                                          queue: queue)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) {
                self.reattach()
            }
            self.coalescer.schedule()
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        pollTimer?.cancel()
        pollTimer = nil
        coalescer.schedule()
    }

    private func reattach() {
        source?.cancel()
        source = nil
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attachOrPoll() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.path.path) {
                self.attachOrPoll()
            }
        }
        pollTimer = t
        t.resume()
    }
}
