// Where this app was when it created the registration that exists now.
//
// docs/app-design.md asks the app to "compare its own bundle path against what the
// registration resolves to". Stage 3 measured that the second half of that sentence has no
// answer: `launchctl print` gives `program identifier = Contents/MacOS/micpeg`, a
// bundle-relative path, plus `parent bundle identifier`; SMAppService exposes no path at all;
// and the only source that does hold one, `sfltool dumpbtm`, demands an administrator
// password, which rules it out of a shipping app for good.
//
// The pid is a partial substitute — proc_pidpath on the running daemon says which bundle it
// came out of — and it is not enough. A shell `mv` carries the inode with the bundle, so the
// daemon that was already running reports the *new* path while launchd still holds the old
// one. Measured: after moving Micpeg.app to ~/Applications, the survey read HEALTHY, and it
// was wrong. The registration was broken and only the next spawn would have shown it.
//
// So the app records the path itself, at the moment it registers. A recorded path that no
// longer matches this bundle is proof of a move, needs no daemon to be running, and cannot be
// faked by an inode following the file. It is one-way evidence: its absence proves nothing
// (a fresh install, a cleared preference), so it never contributes to a healthy verdict — it
// only takes one away.
//
// UserDefaults rather than ~/.config/micpeg: that directory is the daemon's, read by the
// daemon on every config change, and this is bookkeeping about the app's own registration
// which the daemon has no business parsing.

import Foundation

enum RegistrationRecord {
    private static let pathKey = "registeredFromBundlePath"
    private static let dateKey = "registeredAt"

    struct Value {
        let bundlePath: String
        let at: Date?
    }

    static func read() -> Value? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: pathKey) else { return nil }
        return Value(bundlePath: path, at: defaults.object(forKey: dateKey) as? Date)
    }

    /// Written when a registration exists — not when the daemon is confirmed running. The
    /// question this answers is "where was the app when the registration was created", and
    /// that is settled by register() returning, whether or not launchd has spawned anything.
    static func write(bundle: URL = Bundle.main.bundleURL) {
        UserDefaults.standard.set(bundle.path, forKey: pathKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }
}
