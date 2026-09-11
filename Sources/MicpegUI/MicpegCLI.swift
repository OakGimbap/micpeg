// Every mutation the window can make, and the only route it has.
//
// docs/app-design.md's routing table: reads go straight to CoreAudio and to the daemon's
// files; **every** write goes through `Contents/MacOS/micpeg`. That is not a stylistic
// preference. The CLI owns the project's single call to `setDefaultInputDevice` and the single
// place that writes `config.json`, and routing the window through it is what makes
// "the app writes nothing to CoreAudio" and "the app writes no file contents" true by
// construction rather than by review.
//
// The arguments are also the reason `micpeg pick <uid>` exists at all — stage 1 added it for
// exactly this call.

import Foundation

public struct MicpegCLI: Sendable {
    public let executable: URL

    /// The daemon inside this app bundle. The one place that path is spelled: it was written
    /// out in four, and a bundle layout change that missed one would still build and would
    /// silently kill only the window's write path.
    public static var bundledExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/micpeg")
    }

    /// That copy, never whatever is on PATH. A user's `~/.local/bin` symlink may point at a
    /// different install, and the window must act on the daemon it ships with.
    public static var bundled: MicpegCLI { MicpegCLI(executable: bundledExecutable) }

    public init(executable: URL) { self.executable = executable }

    public struct Result: Sendable {
        public var ok: Bool
        public var output: String
    }

    /// Pin a device by UID. The CLI resolves the UID through CoreAudio rather than trusting
    /// the string, so a device that has been unplugged between the sheet opening and the
    /// button being pressed fails with a message instead of writing a pin that cannot act.
    @discardableResult
    public func pick(uid: String) -> Result { run(["pick", uid]) }

    /// Pause and resume. These write `enabled` and send the daemon a SIGHUP; they do not stop
    /// the agent, which is deliberate — docs/app-design.md, "Process model": quitting or
    /// pausing must never look like uninstalling.
    @discardableResult
    public func setEnabled(_ on: Bool) -> Result { run([on ? "on" : "off"]) }

    private func run(_ arguments: [String]) -> Result {
        let (status, output) = runTool(executable.path, arguments)
        return Result(ok: status == 0,
                      output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Run a program to completion: its exit status, and everything it printed on stdout and
/// stderr together. One copy for the app — the window's CLI calls above and the app target's
/// `launchctl` — so there is one place that waits on a child process. The daemon keeps its own
/// (`runTool` in main.swift), since it links nothing from this target.
public func runTool(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (-1, "could not run \(path): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self))
}
