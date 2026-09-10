// "Recent activity", read from the daemon's log.
//
// The log is the daemon's own vocabulary and most of it is not for the user. app-ui.md is
// explicit: "`YIELDED`, `PINNED`, `BACKOFF` are internal state names and must not appear in
// the window." So this file does two things — it throws away the lines that are diagnostics
// (`listeners registered`, `config loaded`, `ARRIVED … output-only`), and it translates the
// ones that are events into sentences.
//
// Translating rather than passing through is also what keeps the window honest about *what
// happened to the user's microphone*, which is the only question they came to ask. A line
// saying `REVERT -> Elgato Wave:1 (dev#, displacing …)` answers it; showing it verbatim does
// not.
//
// Only the tail is read. The daemon truncates its own log, but a window opening must not
// depend on that having happened recently.

import Foundation

public struct Activity: Identifiable, Equatable, Sendable {
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
        case started
    }

    public var id: String { "\(at.timeIntervalSince1970)-\(raw)" }
    public var at: Date
    public var kind: Kind
    /// Kept for the expandable detail and for bug reports. Never shown as the headline.
    public var raw: String

    public init(at: Date, kind: Kind, raw: String) {
        self.at = at
        self.kind = kind
        self.raw = raw
    }
}

public enum ActivityLog {
    /// How much of the end of the file to read. Large enough to hold a busy day, small enough
    /// that opening the window never turns into reading a megabyte.
    private static let tailBytes = 64 * 1024

    public static func recent(_ limit: Int = 20, from url: URL = DaemonPaths.log) -> [Activity] {
        parse(tail(of: url)).suffix(limit).reversed()
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

    static func parse(_ text: String) -> [Activity] {
        text.split(separator: "\n").compactMap { parse(line: String($0)) }
    }

    /// `2026-09-10 23:03:26.283 PINNED -> YIELDED: user chose MacBook Pro Microphone [bltn] — respecting`
    static func parse(line: String) -> Activity? {
        // The stamp is a fixed 23 characters, and splitting on spaces would break every device
        // name with a space in it.
        guard line.count > 24 else { return nil }
        let stampEnd = line.index(line.startIndex, offsetBy: 23)
        guard let at = DaemonState.stamp.date(from: String(line[line.startIndex..<stampEnd]))
        else { return nil }
        let message = String(line[line.index(after: stampEnd)...])
        guard let kind = classify(message) else { return nil }
        return Activity(at: at, kind: kind, raw: message)
    }

    private static func classify(_ message: String) -> Activity.Kind? {
        // REVERT -> Elgato Wave:1 (dev#, displacing MW's AirPods Pro 3 [blue])
        if message.hasPrefix("REVERT -> ") {
            let rest = String(message.dropFirst("REVERT -> ".count))
            let name = String(rest.prefix(while: { $0 != "(" }))
                .trimmingCharacters(in: .whitespaces)
            var displaced: String?
            if let range = rest.range(of: "displacing ") {
                displaced = stripTransportTag(String(rest[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ") ")))
            }
            return .restored(to: name, displacing: displaced)
        }

        // PINNED -> YIELDED: user chose MacBook Pro Microphone [bltn] — respecting
        if message.contains("-> YIELDED"), let chosen = after("user chose ", in: message) {
            return .steppedAside(to: stripTransportTag(
                chosen.replacingOccurrences(of: " — respecting", with: "")
                      .replacingOccurrences(of: "settled Bluetooth device ", with: "")))
        }
        if message.contains("-> PINNED") {
            // YIELDED -> PINNED means the user's own choice went back to the target;
            // ABSENT -> PINNED is a fresh pin.
            return message.hasPrefix("YIELDED") ? .resumed : .pinned
        }
        if message.contains("-> ABSENT") { return .targetMissing }
        if message.contains("-> BACKOFF") { return .backedOff }
        if message.contains(" starting (pid ") { return .started }

        // Everything else is diagnostics: listeners registered, config loaded, ARRIVED …,
        // SIGHUP, the stderr redirect. None of it is an answer to "is my microphone right".
        return nil
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
