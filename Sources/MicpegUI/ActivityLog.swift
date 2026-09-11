// "Activity", read from the daemon's log.
//
// The log is the daemon's own vocabulary and most of it is not for the user. app-ui.md is
// explicit: "`YIELDED`, `PINNED`, `BACKOFF` are internal state names and must not appear in
// the window." So this file throws away the lines that are diagnostics and turns the rest into
// rows: who acted, and which microphone moved where.
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
// and `FROM`/`TO` are exactly `DaemonState.Kind`'s raw values. Anything that is neither a
// transition nor one of the few other event lines is not an event, explicitly, rather than
// being silently dropped for failing to match a prefix.
//
// The first draft dropped the failure lines — `REVERT FAILED`, `RE-VERIFY FAILED`, `FATAL:`,
// `WARNING:` — so the single most important thing that can happen to this user, micpeg trying
// to put the microphone back and failing, left no trace in the window at all. They are still
// classified first.
//
// **The second draft reported things that had not happened.** Of the ten rows in the
// screenshot that prompted this rewrite, not one was Micpeg defending the microphone: every
// "Moved your microphone back" was `REVERT … (SIGHUP, …)` — the config being reloaded because
// the user had just picked a microphone in this app — and every "Selected Elgato Wave:1." was
// the daemon starting. Three facts about the log account for it, and each is why something
// below has the shape it has:
//
//   - A REVERT's reason names its trigger. `SIGHUP` is the user acting through this app; every
//     other trigger is Micpeg acting (main.swift:364, :446, :529, :711, :807, :1223).
//   - The SIGHUP handler resets YIELDED, PAUSED and BACKOFF to ABSENT *without logging it*
//     (main.swift:1216-1217), so a Resume reads `ABSENT -> PINNED: SIGHUP`, the same line as a
//     pick. Telling them apart needs the previous transition, which is why the pass below runs
//     oldest first instead of newest first and stopping early.
//   - A successful revert logs `REVERT -> T (reason)` and then a transition carrying the same
//     reason text (main.swift:668-669). They are one event, merged on that text. The first
//     version merged on a two-second window, which is a guess about timing standing in for a
//     fact the log states outright.
//
// The whole file is read. The daemon truncates it to zero past 256 KB (main.swift:811-817), so
// there is never more than that, and the history on offer is exactly as deep as that allows.

import CoreAudio
import Foundation

public struct Activity: Identifiable, Equatable, Sendable {
    /// Who moved the microphone. The row's badge says this before anything is read.
    public enum Actor: Equatable, Sendable {
        /// Micpeg put the microphone back — the program doing its job.
        case micpeg
        /// A choice in this app or in System Settings, or Pause and Resume.
        case you
        /// Neither: the daemon started, or the kept microphone came or went.
        case system
        /// Something went wrong.
        case problem
    }

    /// A microphone as the log names it.
    public struct Device: Equatable, Sendable {
        public var name: String
        /// From the `[xxxx]` tag the daemon writes after some names (main.swift:576, :626). nil
        /// where it writes none — `auto-switch to <name>` has no tag — and the window then looks
        /// the name up among the devices connected now.
        public var transport: UInt32?

        public init(name: String, transport: UInt32? = nil) {
            self.name = name
            self.transport = transport
        }
    }

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
        /// Micpeg put the microphone back: a device arrived, macOS switched on its own, the
        /// audio system reset, or the daemon started with another input selected.
        case restored(to: Device, from: Device?)
        /// A pick in this app. Both are nil when the chosen microphone was already the input,
        /// because the log then names no device.
        case chose(to: Device?, from: Device?)
        /// A choice made outside Micpeg, which it stepped aside for.
        case switchedAway(to: Device)
        /// The user chose the kept microphone again after switching away.
        case switchedBack
        case paused
        /// Resume. The log has no line of its own for it; see the file header.
        case resumed(to: Device?, from: Device?)
        case started
        /// The kept microphone is connected again.
        case reconnected
        /// The microphone the user had switched to went away, so the kept one is back.
        case backInUse
        /// The kept microphone is not connected.
        case disconnected
        /// Repeated fights with another program; the daemon backed off.
        case backedOff
        case problem(Problem)

        public var actor: Actor {
            switch self {
            case .restored:                                          return .micpeg
            case .chose, .switchedAway, .switchedBack, .paused, .resumed: return .you
            case .started, .reconnected, .backInUse, .disconnected:  return .system
            case .backedOff, .problem:                               return .problem
            }
        }
    }

    public let id: String
    public var at: Date
    public var kind: Kind
    /// How many identical entries in a row this one stands for. See `ActivityLog.collapsed`.
    public var count: Int
    /// Kept for `MicpegApp activity` and for bug reports. Never shown in the window.
    public var raw: String
    public var actor: Actor { kind.actor }

    public init(at: Date, kind: Kind, raw: String, count: Int = 1) {
        self.init(id: "\(at.timeIntervalSince1970)-\(raw)", at: at, kind: kind, raw: raw,
                  count: count)
    }

    init(id: String, at: Date, kind: Kind, raw: String, count: Int) {
        self.id = id
        self.at = at
        self.kind = kind
        self.raw = raw
        self.count = count
    }
}

public enum ActivityLog {
    /// A little over the daemon's 256 KB truncation threshold (main.swift:814), because it checks
    /// before appending a transition rather than after every line. In practice, the whole file.
    private static let tailBytes = 320 * 1024

    /// Newest first, collapsed.
    public static func recent(_ limit: Int = 200, from url: URL = DaemonPaths.log) -> [Activity] {
        Array(collapsed(activities(in: tail(of: url))).prefix(limit))
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

    /// Every event in `text`, newest first, not yet collapsed.
    ///
    /// One pass, oldest line first, carrying the two pieces of context the log leaves implicit:
    /// the last state a transition *said* — the SIGHUP handler's silent reset means that is not
    /// the state the next line's FROM claims — and the reason of a REVERT whose transition line
    /// may be next.
    static func activities(in text: String) -> [Activity] {
        let lines = text.split(separator: "\n").compactMap(Line.init)
        var out: [Activity] = []
        var lastState: DaemonState.Kind?
        var openRevert: Substring?
        for (index, line) in lines.enumerated() {
            let revertReason = openRevert
            openRevert = nil
            let kind: Activity.Kind?
            if let problem = problem(in: line.message) {
                kind = .problem(problem)
            } else if line.message.hasPrefix("RE-VERIFY -> ") {
                // The second write of a REVERT already on screen (main.swift:688).
                kind = nil
            } else if let revert = Revert(line.message) {
                openRevert = revert.reason
                kind = revert.kind(after: lastState)
            } else if let transition = Transition(line.message) {
                let isRevertEcho = revertReason.map { transition.reason == $0 } ?? false
                let next = index + 1 < lines.count ? lines[index + 1] : nil
                kind = isRevertEcho ? nil : transition.kind(after: lastState, line: line, next: next)
                lastState = transition.to
            } else {
                kind = nil
            }
            guard let kind, let at = line.date else { continue }
            out.append(Activity(at: at, kind: kind, raw: String(line.message)))
        }
        return out.reversed()
    }

    /// Adjacent entries that would draw the same row become one row with a count rather than
    /// being dropped: a run of daemon restarts is one "Started ×5", and the count is itself
    /// information that the first version threw away. Never across a day boundary — the day
    /// header between them would split the run anyway.
    ///
    /// The row keeps the newest time and the *oldest* member's id, so the next duplicate bumps
    /// the count of the row already on screen instead of inserting a new one above it.
    static func collapsed(_ newestFirst: [Activity]) -> [Activity] {
        var out: [Activity] = []
        let calendar = Calendar.current
        for entry in newestFirst {
            if let last = out.last, last.kind == entry.kind,
               calendar.isDate(last.at, inSameDayAs: entry.at) {
                out[out.count - 1] = Activity(id: entry.id, at: last.at, kind: last.kind,
                                              raw: last.raw, count: last.count + entry.count)
            } else {
                out.append(entry)
            }
        }
        return out
    }

    // MARK: - Lines

    /// An event line. The stamp stays text until a row needs it as a date: most lines never
    /// become rows, and parsing a stamp is the slowest thing on this path.
    ///
    /// Split on the first two spaces rather than a character count: the stamp's width is
    /// already decided by `DaemonState.stamp`'s format string, and restating it as `23` here
    /// would be a second place to keep in sync.
    private struct Line {
        let stamp: String
        let message: Substring

        init?(_ line: Substring) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, ActivityLog.isEvent(parts[2]) else { return nil }
            stamp = "\(parts[0]) \(parts[1])"
            message = parts[2]
        }

        var date: Date? { DaemonState.date(fromStamp: stamp) }
    }

    /// Cheap and deliberately loose: it only has to keep the ~90% of lines that are diagnostics
    /// out of the pass. What survives is classified properly below.
    private static func isEvent(_ message: Substring) -> Bool {
        if message.hasPrefix("RE") || message.hasPrefix("FATAL:") || message.hasPrefix("WARNING:") {
            return true
        }
        guard let space = message.firstIndex(of: " ") else { return false }
        return DaemonState.Kind(rawValue: String(message[..<space])) != nil
    }

    private static func problem(in message: Substring) -> Activity.Problem? {
        if message.hasPrefix("REVERT FAILED") || message.hasPrefix("RE-VERIFY FAILED") {
            return .restoreFailed
        }
        if message.hasPrefix("FATAL:") { return .audioSystemLost }
        if message.hasPrefix("WARNING:") {
            if message.contains("config is malformed") { return .settingsUnreadable }
            if message.contains("state.json") { return .statusNotSaved }
        }
        return nil
    }

    /// `REVERT -> <target> (<reason>)` (main.swift:668). The reason has one of two shapes, and
    /// both are found by their literal text rather than by the first "(" — a device name can
    /// contain one, and the first version cut such names short:
    ///
    ///     <trigger>, displacing <name> [<fourcc>]     applyPin(reason:), main.swift:624-626
    ///     <why> to <name>                             evaluate(), main.swift:597-598
    ///
    /// The second shape is the one that matters most — macOS switching to a headset and Micpeg
    /// switching back — and it has no "displacing", so the first version reported it without
    /// saying where the microphone had gone.
    private struct Revert {
        static let triggers = ["SIGHUP", "startup", "dev#", "srst recovery", "input-scope retry",
                               "backoff expired"]
        static let judgements = ["auto-switch", "flip-back", "system churn"]

        let target: Activity.Device
        let displaced: Activity.Device?
        let trigger: Substring
        /// Exactly the text `transition(.pinned, reason)` repeats on the next line.
        let reason: Substring

        init?(_ message: Substring) {
            guard message.hasPrefix("REVERT -> "), message.hasSuffix(")") else { return nil }
            let body = message.dropFirst("REVERT -> ".count).dropLast()
            var anchor: (range: Range<Substring.Index>, trigger: String, tagged: Bool)?
            func consider(_ literal: String, _ trigger: String, tagged: Bool) {
                guard let range = body.range(of: literal) else { return }
                if anchor.map({ range.lowerBound < $0.range.lowerBound }) ?? true {
                    anchor = (range, trigger, tagged)
                }
            }
            for trigger in Self.triggers { consider(" (\(trigger), displacing ", trigger, tagged: true) }
            for why in Self.judgements { consider(" (\(why) to ", why, tagged: false) }

            if let anchor {
                let named = body[anchor.range.upperBound...]
                target = Activity.Device(name: String(body[..<anchor.range.lowerBound]))
                displaced = anchor.tagged ? ActivityLog.device(tagged: named)
                                          : Activity.Device(name: String(named))
                trigger = Substring(anchor.trigger)
                reason = body[body.index(anchor.range.lowerBound, offsetBy: 2)...]
            } else {
                // A trigger this app does not know. Micpeg still wrote the input — that is what
                // a REVERT line is — so it is still a restore, with nothing claimed about where
                // the microphone had been.
                guard let open = body.range(of: " (", options: .backwards) else { return nil }
                target = Activity.Device(name: String(body[..<open.lowerBound]))
                displaced = nil
                reason = body[open.upperBound...]
                trigger = reason
            }
        }

        func kind(after lastState: DaemonState.Kind?) -> Activity.Kind {
            guard trigger == "SIGHUP" else { return .restored(to: target, from: displaced) }
            return lastState == .paused ? .resumed(to: target, from: displaced)
                                        : .chose(to: target, from: displaced)
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

        func kind(after lastState: DaemonState.Kind?, line: Line, next: Line?) -> Activity.Kind? {
            switch to {
            case .yielded:
                return ActivityLog.chosenDevice(in: reason).map { .switchedAway(to: $0) }
            case .pinned:
                // Leaving a backoff changes nothing the user can see; the conflict row has
                // already said what happened.
                if from == .backoff { return nil }
                switch reason {
                case "startup":
                    return .started
                case "SIGHUP":
                    return lastState == .paused ? .resumed(to: nil, from: nil)
                                                : .chose(to: nil, from: nil)
                case "default input is the target":
                    return from == .yielded ? .switchedBack : .reconnected
                case "dev#", "input-scope retry":
                    return .reconnected
                case "yielded device disappeared", "target device re-arrived":
                    // Both are followed in the same call by `applyPin(reason: "dev#")`
                    // (main.swift:433-446). When that pin reverts, the REVERT row already says
                    // what changed; when it does not, this line is the only record that the
                    // kept microphone is in use again.
                    if let next, next.message.hasPrefix("REVERT -> "),
                       let here = line.date, let then = next.date,
                       then.timeIntervalSince(here) < 0.25 {
                        return nil
                    }
                    return reason == "yielded device disappeared" ? .backInUse : .reconnected
                default:
                    // `srst recovery`, `backoff expired`, or a reason this app cannot phrase.
                    // None of them moved the microphone; a REVERT would have, and has its own row.
                    return nil
                }
            case .absent:  return .disconnected
            case .paused:  return .paused
            case .backoff: return .backedOff
            // A state this app does not know cannot be phrased for the user, and guessing which
            // familiar one it resembles is the mistake `DaemonState.Kind.unknown` exists to stop.
            case .unknown: return nil
            }
        }
    }

    /// `user chose <name> [<fourcc>] — respecting` (main.swift:576), or `user chose settled
    /// Bluetooth device <name> — respecting` (:601), which carries no tag but says what it is.
    private static func chosenDevice(in reason: String) -> Activity.Device? {
        var text = Substring(reason)
        if text.hasSuffix(" — respecting") { text = text.dropLast(" — respecting".count) }
        let settled = "user chose settled Bluetooth device "
        if text.hasPrefix(settled) {
            return Activity.Device(name: String(text.dropFirst(settled.count)),
                                   transport: kAudioDeviceTransportTypeBluetooth)
        }
        let chose = "user chose "
        guard text.hasPrefix(chose) else { return nil }
        return device(tagged: text.dropFirst(chose.count))
    }

    /// `MacBook Pro Microphone [bltn]` → the name and its transport. The tag is whatever
    /// `fourCC` printed (CoreAudio.swift:29-37): four characters with spaces kept (`usb `),
    /// `none`, or a decimal for a code that is not printable — so it is found from the last
    /// " [" rather than by counting characters.
    private static func device(tagged text: Substring) -> Activity.Device {
        guard text.hasSuffix("]"), let open = text.range(of: " [", options: .backwards) else {
            return Activity.Device(name: String(text).trimmingCharacters(in: .whitespaces))
        }
        let tag = text[open.upperBound..<text.index(before: text.endIndex)]
        return Activity.Device(name: String(text[..<open.lowerBound]),
                               transport: transportCode(tag: tag))
    }

    /// The inverse of `fourCC`.
    static func transportCode(tag: Substring) -> UInt32? {
        if tag == "none" { return nil }
        let bytes = Array(tag.utf8)
        if bytes.count == 4, bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return bytes.reduce(0) { $0 << 8 | UInt32($1) }
        }
        return UInt32(tag)
    }
}
