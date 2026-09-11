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
import MicpegAudio

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
    /// with it, and the survey prints its times with it for the same reason.
    ///
    /// `en_US_POSIX` on both sides: the daemon's `stampFormatter` sets it too. It did not, and
    /// this file used to parse with the current locale as a fallback on the theory that a
    /// non-Gregorian year would fail here and be rescued there. Measured, it never failed:
    /// this parser read the Buddhist 2569, the Japanese 0008 and even Arabic-Indic digits as
    /// Gregorian years, so the fallback never ran and every row was misdated. The fix was the
    /// daemon's one line, and the fallback went with it.
    public static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - config.json

/// Only the fields the window is allowed to care about. The tuning constants —
/// `debounceMs`, `arrivalWindowSeconds`, `reverifyDelaySeconds`, `postWriteGraceSeconds` —
/// are decoded only to be checked the way the daemon checks them, and are never stored:
/// app-ui.md forbids showing them, and a value that is not kept cannot end up on screen.
public struct PinnedConfig: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var uid: String?
        public var name: String?
        public init(uid: String?, name: String?) { self.uid = uid; self.name = name }
    }

    public var enabled: Bool
    public var priority: [Target]
    /// `blockTransports`, as CoreAudio transport codes. Resolved here, once per read: the first
    /// draft turned each name into a four-character string per device per redraw to compare
    /// against another string built the same way — three allocations to answer a question about
    /// two integers. A name the daemon does not recognise resolves to nothing, as it does there.
    public var blockedTransportCodes: Set<UInt32>

    public init(enabled: Bool, priority: [Target], blockedTransports: [String]) {
        self.enabled = enabled
        self.priority = priority
        self.blockedTransportCodes = Set(blockedTransports.compactMap(transportCode(_:)))
    }

    /// The daemon's default (`Config.fallback` in main.swift), for a file that names none and
    /// for no file at all. The window marks devices ⚠ from this, and it used to fall back to an
    /// empty list: on a fresh install with AirPods connected — the moment macOS has just moved
    /// the input to them — onboarding offered them selected and unmarked, and one click pinned
    /// the device the product exists to undo.
    public static let defaultBlockedTransports = ["bluetooth", "bluetoothle"]
    public static let defaultBlockedTransportCodes =
        Set(defaultBlockedTransports.compactMap(transportCode(_:)))

    /// True when there is nothing for the daemon to enforce. This is app-ui.md's
    /// "unconfigured" state, and it is a different thing from "the pinned device is unplugged".
    public var isUnconfigured: Bool { priority.isEmpty }

    /// What to call the chosen microphone: its name, or its UID for an entry written without
    /// one.
    public var targetName: String? {
        guard let first = priority.first else { return nil }
        return first.name ?? first.uid
    }

    /// The daemon's rule, not a looser one (`Config.init(from:)` in main.swift): a key that is
    /// absent takes the default, and a key that is present must decode as the daemon's type.
    /// Every field here used to be optional and the tuning keys were not looked at, so files the
    /// daemon rejects read as fine — `null` passed as absent, `"debounceMs": 250.5` was never
    /// read — and the window showed its settings while the daemon ran with none. The tuning
    /// values are decoded to be checked and then dropped: app-ui.md keeps them off the screen,
    /// and a value that is never stored cannot end up there.
    private struct Wire: Decodable {
        struct Input: Decodable { var priority: [Ref] }
        struct Ref: Decodable { var uid: String?; var name: String? }
        var enabled: Bool
        var priority: [Ref]
        var blockTransports: [String]

        private enum Key: String, CodingKey {
            case enabled, input, blockTransports
            case arrivalWindowSeconds, debounceMs, reverifyDelaySeconds, postWriteGraceSeconds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func present<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
                c.contains(key) ? try c.decode(type, forKey: key) : nil
            }
            enabled = try present(Bool.self, .enabled) ?? true
            priority = try present(Input.self, .input)?.priority ?? []
            blockTransports = try present([String].self, .blockTransports)
                ?? PinnedConfig.defaultBlockedTransports
            _ = try present(Double.self, .arrivalWindowSeconds)
            _ = try present(Int.self, .debounceMs)
            _ = try present(Double.self, .reverifyDelaySeconds)
            _ = try present(Double.self, .postWriteGraceSeconds)
        }
    }

    public enum ReadResult: Equatable, Sendable {
        case ok(PinnedConfig)
        /// No file. A fresh install, and the app's cue to show onboarding.
        case missing
        /// There is a file and it does not parse. Not the same as `missing`: someone chose a
        /// microphone once, and the daemon keeps whatever it last loaded — none, if it has
        /// restarted since — so the window must not offer to set things up from nothing.
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
                enabled: wire.enabled,
                priority: wire.priority.map { Target(uid: $0.uid, name: $0.name) },
                blockedTransports: wire.blockTransports))
        } catch {
            return .unreadable("\(error)")
        }
    }
}
