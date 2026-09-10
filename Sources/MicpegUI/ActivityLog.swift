// "Recent activity", read from the daemon's log.
//
// The log is the daemon's own vocabulary and most of it is not for the user. app-ui.md is
// explicit: "`YIELDED`, `PINNED`, `BACKOFF` are internal state names and must not appear in
// the window." So this file throws away the lines that are diagnostics and translates the
// rest into sentences.
//
// **Scraping a sibling program's log is the wrong altitude, and it is the only altitude
// available.** `state.json` holds one current state and no history, so it cannot answer "what
// happened to my microphone". The right mechanism is a structured event log the daemon
// appends to — JSONL, one object per event — and that is a daemon change, which is blocked:
// the daemon is finished. Recorded here so the constraint is visible rather than forgotten.
//
// Given that, the parsing is done on the log's *grammar* rather than on a list of hopeful
// prefixes. Every state change the daemon writes has one shape (main.swift, `transition`):
//
//     <FROM> -> <TO>: <reason>
//
// and `FROM`/`TO` are exactly `DaemonState.Kind`'s raw values, a type this target already
// has. Matching the structure and then the typed pair — rather than `contains("-> PINNED")` —
// is what makes the failure lines below impossible to miss: anything that is not a transition
// falls into one explicit bucket instead of being silently dropped for not matching a prefix.
//
// The first draft dropped them. `REVERT FAILED`, `RE-VERIFY FAILED` and the daemon's `FATAL:`
// and `WARNING:` lines matched no prefix, so the single most important thing that can happen
// to this user — micpeg tried to put the microphone back and could not — left no trace in the
// window at all. That is the failure shape CLAUDE.md names, reproduced inside the feature
// built to report it.
//
// Only the tail is read. The daemon truncates its own log, but a window opening must not
// depend on that having happened recently.

import Foundation

public struct Activity: Identifiable, Equatable, Sendable {
    /// Something went wrong, in the user's terms rather than the daemon's. The raw line is
    /// kept on the entry; `OSStatus` values and four-character codes never reach the window.
    public enum Problem: Equatable, Sendable {
        /// `REVERT FAILED` / `RE-VERIFY FAILED` — the write to CoreAudio did not take.
        case restoreFailed
        /// `FATAL: could not add listener` — the daemon cannot watch the audio system.
        case audioSystemLost
        /// `WARNING: cannot write …state.json`.
        case statusNotSaved
        /// `WARNING: config is malformed`.
        case settingsUnreadable
    }

    public enum Kind: Equatable, Sendable {
        /// The daemon put the microphone back. This is the program doing its job.
        case restored(to: String, displacing: String?)
        /// The user picked something else and the daemon stood down.
        case steppedAside(to: String)
        /// The pinned device is back in charge after the user had chosen another.
        /// No device name: the daemon does not put one in these lines, and the window knows
        /// the target already. Inventing one here would be the window guessing.
        case resumed
        /// First pin after a start, or after the device reappeared.
        case pinned
        /// The pinned device is not connected.
        case targetMissing
        /// Repeated fights with another program; the daemon backed off.
        case backedOff
        case problem(Problem)
    }

    public let id: String
    public var at: Date
    public var kind: Kind
    /// Kept for the expandable detail and for bug reports. Never shown as the headline.
    public var raw: String

    public init(at: Date, kind: Kind, raw: String) {
        self.at = at
        self.kind = kind
        self.raw = raw
        self.id = "\(at.timeIntervalSince1970)-\(raw)"
    }
}

public enum ActivityLog {
    /// How much of the end of the file to read. Large enough to hold a busy day, small enough
    /// that opening the window never turns into reading a megabyte.
    private static let tailBytes = 64 * 1024

    /// Newest first.
    ///
    /// Walks backwards and stops once it has enough. Measured on the real log, the 64 KB tail
    /// is ~983 lines of which ~96 are events; parsing all of them to keep 20 meant ~950
    /// `DateFormatter` parses — the slowest thing in Foundation's string layer — thrown away.
    public static func recent(_ limit: Int = 20, from url: URL = DaemonPaths.log) -> [Activity] {
        var out: [Activity] = []
        for line in tail(of: url).split(separator: "\n").reversed() {
            if let activity = parse(line: line) { out.append(activity) }
            if out.count == limit { break }
        }
        return out
    }

    static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        // The first line is probably cut in half by the byte offset.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    /// `2026-09-10 23:03:26.283 PINNED -> YIELDED: user chose MacBook Pro Microphone [bltn] — respecting`
    ///
    /// Split on the first two spaces rather than a character count: the stamp's width is
    /// already decided by `DaemonState.stamp`'s format string, and restating it as `23` here
    /// would be a second place to keep in sync. Classification runs before the date is parsed,
    /// because most lines are diagnostics and parsing their stamps is pure waste.
    static func parse(line: Substring) -> Activity? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let message = parts[2]
        guard let kind = classify(message) else { return nil }
        guard let at = DaemonState.stamp.date(from: "\(parts[0]) \(parts[1])") else { return nil }
        return Activity(at: at, kind: kind, raw: String(message))
    }

    private static func classify(_ message: Substring) -> Activity.Kind? {
        // Failures first. These are the lines the window most needs and the ones a
        // prefix-matching classifier silently drops.
        if message.hasPrefix("REVERT FAILED") || message.hasPrefix("RE-VERIFY FAILED") {
            return .problem(.restoreFailed)
        }
        if message.hasPrefix("FATAL:") { return .problem(.audioSystemLost) }
        if message.hasPrefix("WARNING:") {
            if message.contains("config is malformed") { return .problem(.settingsUnreadable) }
            if message.contains("state.json") { return .problem(.statusNotSaved) }
            return nil
        }

        // REVERT -> Elgato Wave:1 (dev#, displacing MW's AirPods Pro 3 [blue])
        if message.hasPrefix("REVERT -> ") {
            let rest = message.dropFirst("REVERT -> ".count)
            let name = String(rest.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
            var displaced: String?
            if let range = rest.range(of: "displacing ") {
                displaced = stripTransportTag(String(rest[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ") ")))
            }
            return .restored(to: name, displacing: displaced)
        }

        // Everything else that matters is a transition, and every transition has one shape.
        guard let transition = Transition(message) else { return nil }
        switch transition.to {
        case .yielded:
            let chosen = after("user chose ", in: transition.reason) ?? ""
            return .steppedAside(to: stripTransportTag(
                chosen.replacingOccurrences(of: " — respecting", with: "")
                      .replacingOccurrences(of: "settled Bluetooth device ", with: "")))
        case .pinned:  return transition.from == .yielded ? .resumed : .pinned
        case .absent:  return .targetMissing
        case .backoff: return .backedOff
        case .paused:  return nil
        // A state this app does not know cannot be phrased for the user, and guessing which
        // familiar one it resembles is the mistake `DaemonState.Kind.unknown` exists to stop.
        case .unknown: return nil
        }
    }

    /// `<FROM> -> <TO>: <reason>`, with both sides resolved against `DaemonState.Kind`.
    ///
    /// A line whose `TO` is not a state this app knows is not a transition as far as it is
    /// concerned, and is dropped rather than guessed at — the same rule `DaemonState` adopts
    /// for the state file.
    private struct Transition {
        let from: DaemonState.Kind
        let to: DaemonState.Kind
        let reason: String

        init?(_ message: Substring) {
            guard let arrow = message.range(of: " -> "),
                  let colon = message[arrow.upperBound...].firstIndex(of: ":"),
                  let from = DaemonState.Kind(rawValue: String(message[..<arrow.lowerBound])),
                  let to = DaemonState.Kind(rawValue: String(message[arrow.upperBound..<colon]))
            else { return nil }
            self.from = from
            self.to = to
            self.reason = String(message[message.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func after(_ marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        return String(text[range.upperBound...])
    }

    /// `MacBook Pro Microphone [bltn]` → `MacBook Pro Microphone`. app-ui.md allows the
    /// transport tags in the device list, where they are a column; inside a sentence they read
    /// as debris.
    private static func stripTransportTag(_ name: String) -> String {
        guard let bracket = name.firstIndex(of: "[") else {
            return name.trimmingCharacters(in: .whitespaces)
        }
        return String(name[name.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
    }
}
