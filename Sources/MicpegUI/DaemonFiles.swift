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
    }

    public var kind: Kind
    public var reason: String
    public var target: String
    public var currentInput: String
    public var updated: Date?
    /// The raw string, kept because a state the app does not recognise is worth showing
    /// rather than silently mapping onto something familiar.
    public var rawKind: String

    public init(kind: Kind, reason: String, target: String, currentInput: String,
                updated: Date?, rawKind: String) {
        self.kind = kind
        self.reason = reason
        self.target = target
        self.currentInput = currentInput
        self.updated = updated
        self.rawKind = rawKind
    }

    private struct Wire: Decodable {
        var state: String
        var reason: String
        var target: String
        var currentInput: String
        var updated: String
    }

    /// nil means the daemon has never written a state file here.
    public static func read(from url: URL = DaemonPaths.state) -> DaemonState? {
        guard let data = try? Data(contentsOf: url),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return DaemonState(kind: Kind(rawValue: wire.state) ?? .absent,
                           reason: wire.reason,
                           target: wire.target,
                           currentInput: wire.currentInput,
                           updated: stamp.date(from: wire.updated),
                           rawKind: wire.state)
    }

    /// The daemon's format, and the reason this is not ISO8601: it is the same string that
    /// goes into the log, so the two can be lined up by eye.
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// A state file the daemon stopped updating is the shape a dead daemon leaves behind.
    /// This says how old it is; whether that is alarming is the caller's judgement, because
    /// a healthy daemon writes only when something changes and can be quiet for days.
    public var age: TimeInterval? {
        updated.map { Date().timeIntervalSince($0) }
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
