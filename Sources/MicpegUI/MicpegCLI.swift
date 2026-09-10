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

    /// The copy inside this app bundle, never whatever is on PATH. A user's `~/.local/bin`
    /// symlink may point at a different install, and the window must act on the daemon it
    /// ships with.
    public static var bundled: MicpegCLI {
        MicpegCLI(executable: Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/micpeg"))
    }

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
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch {
            return Result(ok: false, output: "could not run \(executable.path): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Result(ok: task.terminationStatus == 0,
                      output: String(decoding: data, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
