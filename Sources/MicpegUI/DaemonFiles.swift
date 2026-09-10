// The two files the daemon owns, read by the app and never written by it.
//
// docs/app-design.md's routing table: the app reads `state.json` for daemon state and shells
// out to the CLI for every mutation. `config.json` is read too — app-ui.md defines the
// unconfigured state as "no config.json, or an empty priority list", and `state.json` cannot
// answer that question: a target that was never set and a target that is merely unplugged
// both appear as `(absent)`.
//
// Nothing here writes. `scripts/invariants.sh` fails the build if `.write(to:` or
// `createFile` appears anywhere in Sources/MicpegUI or Sources/MicpegApp, which is what makes
// "your pinned microphone cannot be lost to a bug in the settings window" a structural fact
// rather than a promise.

import Foundation

/// Where the daemon keeps things. Duplicated from the daemon rather than shared: these are a
/// read-only mirror of a format the daemon owns, and a shared type would invite the app to
/// start writing through it.
public enum DaemonPaths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let directory = home.appendingPathComponent(".config/micpeg")
    public static let state = directory.appendingPathComponent("state.json")
    public static let config = directory.appendingPathComponent("config.json")
    public static let log = home.appendingPathComponent("Library/Logs/micpeg.log")
}

// MARK: - state.json

public struct DaemonState: Equatable, Sendable {
    /// The daemon's own vocabulary. It must never reach the window — app-ui.md: "`YIELDED`,
    /// `PINNED`, `BACKOFF` are internal state names and must not appear in the window."
    public enum Kind: String, Sendable {
        case absent  = "ABSENT"
        case pinned  = "PINNED"
        case yielded = "YIELDED"
        case paused  = "PAUSED"
        case backoff = "BACKOFF"
        /// A state this app does not know. Decoding it as `.absent` would be the window
        /// quietly claiming the microphone is missing on the strength of a word it could not
        /// read; this says so instead.
        case unknown
    }

    public var kind: Kind
    public var currentInput: String

    public init(kind: Kind, currentInput: String) {
        self.kind = kind
        self.currentInput = currentInput
    }

    /// Only the two fields the window reads. `reason`, `target` and `updated` are in the file
    /// and are deliberately not decoded, on the same rule `PinnedConfig` states below: a field
    /// that is not read cannot accidentally end up on screen, and `reason` in particular is
    /// the daemon's own phrasing.
    private struct Wire: Decodable {
        var state: String
        var currentInput: String
    }

    /// nil means the daemon has never written a state file here.
    public static func read(from url: URL = DaemonPaths.state) -> DaemonState? {
        guard let data = try? Data(contentsOf: url),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return DaemonState(kind: Kind(rawValue: wire.state) ?? .unknown,
                           currentInput: wire.currentInput)
    }

    /// The daemon's format, and the reason this is not ISO8601: it is the same string that
    /// goes into the log, so the two can be lined up by eye. `ActivityLog` parses log stamps
    /// with it.
    ///
    /// `en_US_POSIX` because a fixed format string without it is interpreted in the user's
    /// locale. **The daemon's own formatter (`main.swift`, `stampFormatter`) does not set a
    /// locale**, so on a system configured for a non-Gregorian calendar the two would disagree
    /// and every activity line would silently vanish. Fixing that is a daemon change and the
    /// daemon is finished; recorded here rather than done.
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The same format read in whatever locale and calendar the daemon is writing in.
    private static let stampInCurrentLocale: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Parse a stamp the daemon wrote.
    ///
    /// POSIX first, then the current locale. The fallback exists because the daemon's
    /// formatter sets no locale, so on a Mac whose region selects a non-Gregorian calendar it
    /// writes a Japanese or Buddhist year — and a POSIX-only parser would reject every line,
    /// emptying "Recent activity" with nothing to show why. The one-line fix belongs in the
    /// daemon; the daemon is finished, so the app absorbs it instead.
    static func date(fromStamp text: String) -> Date? {
        stamp.date(from: text) ?? stampInCurrentLocale.date(from: text)
    }
}

// MARK: - config.json

/// Only the fields the window is allowed to care about. The tuning constants —
/// `debounceMs`, `arrivalWindowSeconds`, `reverifyDelaySeconds`, `postWriteGraceSeconds` —
/// are deliberately not decoded: app-ui.md forbids showing them, and a field that is not read
/// cannot accidentally end up on screen.
public struct PinnedConfig: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var uid: String?
        public var name: String?
        public init(uid: String?, name: String?) { self.uid = uid; self.name = name }
    }

    public var enabled: Bool
    public var priority: [Target]
    public var blockedTransports: [String]

    public init(enabled: Bool, priority: [Target], blockedTransports: [String]) {
        self.enabled = enabled
        self.priority = priority
        self.blockedTransports = blockedTransports
    }

    /// True when there is nothing for the daemon to enforce. This is app-ui.md's
    /// "unconfigured" state, and it is a different thing from "the pinned device is unplugged".
    public var isUnconfigured: Bool { priority.isEmpty }

    private struct Wire: Decodable {
        struct Input: Decodable { var priority: [Ref] }
        struct Ref: Decodable { var uid: String?; var name: String? }
        var enabled: Bool?
        var input: Input?
        var blockTransports: [String]?
    }

    public enum ReadResult: Equatable, Sendable {
        case ok(PinnedConfig)
        /// No file. A fresh install, and the app's cue to show onboarding.
        case missing
        /// There is a file and it does not parse. Not the same as `missing`: the daemon keeps
        /// running on its last good settings, so the window must not offer to set things up
        /// as if nothing were there.
        case unreadable(String)
    }

    public static func read(from url: URL = DaemonPaths.config) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable("could not be read")
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            return .ok(PinnedConfig(
                enabled: wire.enabled ?? true,
                priority: (wire.input?.priority ?? []).map { Target(uid: $0.uid, name: $0.name) },
                blockedTransports: wire.blockTransports ?? []))
        } catch {
            return .unreadable("\(error)")
        }
    }
}
