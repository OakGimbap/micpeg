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
// So this watches the *directory*. A rename into it is a directory write, and re-reading from
// the path picks up whichever inode is there now. Measured — see docs/verification.md.
//
// The directory may not exist at all on a fresh install; the daemon creates it on its first
// write. In that case there is nothing to attach to, so the watcher polls at 1 Hz until the
// directory appears and then attaches. The window is open for seconds at a time, so this
// costs nothing that matters, and it means onboarding sees the config the moment the CLI
// creates it.

import Foundation

/// Calls `onChange` on the main queue whenever the watched directory changes, coalescing
/// bursts. Stops when deinitialised.
public final class DirectoryWatch {
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.micpeg.app.watch")
    private let coalescer: Coalescer

    public init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.coalescer = Coalescer(delay: DaemonTiming.coalesce,
                                   queue: DispatchQueue(label: "com.micpeg.app.watch.coalesce"),
                                   onFire: onChange)
        queue.async { [weak self] in self?.attachOrPoll() }
    }

    deinit {
        coalescer.cancel()
        source?.cancel()
        pollTimer?.cancel()
        // The cancel handler closes `descriptor`; if no source was ever created, close it here.
        if source == nil && descriptor >= 0 { close(descriptor) }
    }

    // MARK: - Attaching

    private func attachOrPoll() {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            startPollingForDirectory()
            return
        }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            startPollingForDirectory()
            return
        }
        descriptor = fd
        // .write covers a rename into the directory, which is what an atomic write looks like
        // from here. .delete and .rename cover the directory itself going away, which is the
        // case that has to re-arm rather than go quiet.
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
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
        descriptor = -1
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attachOrPoll() }
    }

    private func startPollingForDirectory() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.directory.path) {
                self.attachOrPoll()
            }
        }
        pollTimer = t
        t.resume()
    }

}
