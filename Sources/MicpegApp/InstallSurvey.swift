// What is actually installed on this machine, read without changing any of it.
//
// Stage 3 is migration, and migration is the one operation that tears down a working setup
// before it builds the replacement. So the survey comes first and is separate: every action
// in Migration.swift takes a survey before it acts and another one after, and reports both.
// An action that reports what it *did* rather than what is now *true* is the same class of
// claim as a daemon with no listeners writing "watching" to its log.
//
// Two sources of truth here are weaker than they look, and neither is used as a gate:
//
//   - SMAppService.statusForLegacyPlist(at:). The SDK header says this exists for apps
//     "unable to adopt the new daemon and agent packaging guidelines but still want to know
//     when a user disables its legacy daemons or agents" — it is a monitoring API for apps
//     that are staying legacy, not a migration API. It has also been reported returning
//     .notFound for installed, running services since macOS 14.5
//     (developer.apple.com/forums/thread/750685, no Apple reply). It is called and recorded
//     as evidence. The legacy install is *detected* by the plist being on disk.
//
//   - `launchctl print`'s output format is not a contract. Correctness here rests on the
//     exit status (is there a job under this label at all) and on `pid = N`; everything else
//     parsed out of it is reported to the user as text and never decides anything.

import Darwin
import Foundation
import MicpegUI
import ServiceManagement

/// Where the `micpeg` on the user's PATH points, if it is there at all.
enum CLIState {
    case absent
    /// `resolves` is false for a link whose destination is not there — what moving or
    /// deleting the app leaves behind, and what `FileManager.fileExists` would have hidden
    /// by following the link and reporting nothing at all.
    case symlink(to: URL, resolves: Bool)
    case regularFile
    case other(String)

    var isLegacyCopy: Bool {
        if case .regularFile = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .absent:
            return "absent"
        case .symlink(let dest, let resolves):
            return "symlink -> \(dest.path)\(resolves ? "" : "  (DANGLING — nothing there)")"
        case .regularFile:
            return "a regular file (the standalone CLI install)"
        case .other(let what):
            return what
        }
    }
}

/// The launchd job under `com.micpeg.agent`, whoever put it there.
struct JobState {
    let present: Bool
    let pid: pid_t?
    /// The executable the running daemon was launched from, via proc_pidpath. This is the
    /// only way the app can learn which bundle the registration resolves to: launchctl
    /// prints `program identifier = Contents/MacOS/micpeg`, a bundle-relative path, and
    /// SMAppService has no property that exposes it.
    let runningExecutable: URL?
    let managedBy: String?
    let lastExitCode: String?

    static let none = JobState(present: false, pid: nil, runningExecutable: nil,
                               managedBy: nil, lastExitCode: nil)
}

struct InstallSurvey {
    // The bundle asking the question.
    let bundleURL: URL
    let bundledDaemon: URL

    // The hand-written LaunchAgent from `micpeg install`.
    let legacyPlist: URL
    let legacyPlistExists: Bool
    let legacyProgram: String?
    let legacyAPIStatus: SMAppService.Status

    // The label, as launchd sees it.
    let job: JobState

    // The registration this app owns.
    let serviceStatus: SMAppService.Status

    // The CLI on PATH, and the daemon's own state file.
    let cli: CLIState
    let cliPath: URL
    let stateUpdated: Date?

    /// Where this app was when it last created a registration. See RegistrationRecord.swift
    /// for why the app has to remember this itself.
    let registeredFrom: RegistrationRecord.Value?

    /// True when there is a record and it names somewhere other than here.
    var hasMoved: Bool {
        guard let recorded = registeredFrom?.bundlePath else { return false }
        return URL(fileURLWithPath: recorded).standardizedFileURL != bundleURL.standardizedFileURL
    }

    // MARK: - Verdict

    enum Verdict {
        /// Registered here, and the daemon that is running came out of this bundle.
        case healthy
        /// The hand-written LaunchAgent is still on disk. Nothing else matters until it is gone.
        case legacyPresent
        /// The app has moved since it registered. Measured: a running daemon is no evidence
        /// against this — a shell `mv` carries the inode, so the process reports the new path
        /// while the registration may still be describing the old one.
        case moved(from: String)
        /// Something is enforcing the label from a different bundle.
        case foreignBundle(URL)
        /// A job exists but nothing is running it, or the app is not registered while a job
        /// is present — the shape a moved or deleted bundle leaves behind.
        case stale
        case requiresApproval
        case notRegistered
    }

    var verdict: Verdict {
        if legacyPlistExists { return .legacyPresent }
        if serviceStatus == .requiresApproval { return .requiresApproval }
        if hasMoved, let from = registeredFrom?.bundlePath { return .moved(from: from) }
        if let running = job.runningExecutable {
            return running == bundledDaemon.resolvingSymlinksInPath()
                ? .healthy
                : .foreignBundle(running)
        }
        if job.present { return .stale }
        return serviceStatus == .enabled ? .stale : .notRegistered
    }

    /// What the verdict means, in the words the user would need. Stage 4 owns the real
    /// wording; this is here so the harness and the terminal front end say the same thing.
    var explanation: String {
        switch verdict {
        case .healthy:
            return "the agent is registered by this app and the daemon is running from this bundle"
        case .legacyPresent:
            return "a hand-written LaunchAgent from the CLI install is still on disk; it holds the"
                 + " same label, so registering on top of it changes nothing"
        case .moved(let from):
            return "this app registered from \(from) and is now at \(bundleURL.path);"
                 + " re-register from here"
        case .foreignBundle(let running):
            return "the daemon holding this label is running from \(running.path), not from this"
                 + " bundle"
        case .stale:
            return "a launchd job exists under this label but no daemon is running from it"
        case .requiresApproval:
            return "registered, but switched off in Login Items — only the user can undo that"
        case .notRegistered:
            return "nothing is registered under this label"
        }
    }

    // MARK: - Taking the survey

    static var serviceTarget: String { "gui/\(getuid())/\(AgentController.label)" }

    static func take() -> InstallSurvey {
        let home = DaemonPaths.home
        let bundle = Bundle.main.bundleURL
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(AgentController.plistName)")
        let cliPath = home.appendingPathComponent(".local/bin/micpeg")
        let fm = FileManager.default

        var program: String?
        if let data = try? Data(contentsOf: plist),
           let root = try? PropertyListSerialization
               .propertyList(from: data, format: nil) as? [String: Any] {
            program = (root["ProgramArguments"] as? [String])?.first
                ?? (root["Program"] as? String)
        }

        let updated = (try? fm.attributesOfItem(atPath: DaemonPaths.state.path)[.modificationDate])
            as? Date

        return InstallSurvey(
            bundleURL: bundle,
            bundledDaemon: MicpegCLI.bundledExecutable,
            legacyPlist: plist,
            legacyPlistExists: fm.fileExists(atPath: plist.path),
            legacyProgram: program,
            legacyAPIStatus: SMAppService.statusForLegacyPlist(at: plist),
            job: readJob(),
            serviceStatus: AgentController.service.status,
            cli: readCLI(at: cliPath),
            cliPath: cliPath,
            stateUpdated: updated,
            registeredFrom: RegistrationRecord.read())
    }

    private static func readCLI(at path: URL) -> CLIState {
        // lstat, not FileManager.fileExists: fileExists follows the link, so a symlink left
        // dangling by a deleted app would read as "absent" and the app would offer to create
        // one that is already there.
        var info = stat()
        guard lstat(path.path, &info) == 0 else { return .absent }
        switch info.st_mode & S_IFMT {
        case mode_t(S_IFLNK):
            let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path))
                .map { URL(fileURLWithPath: $0) } ?? path
            return .symlink(to: dest,
                            resolves: FileManager.default.isExecutableFile(atPath: dest.path))
        case mode_t(S_IFREG):
            return .regularFile
        case mode_t(S_IFDIR):
            return .other("a directory")
        default:
            return .other("neither a file nor a symlink (mode \(String(info.st_mode, radix: 8)))")
        }
    }

    private static func readJob() -> JobState {
        let (status, out) = runTool("/bin/launchctl", ["print", serviceTarget])
        guard status == 0 else { return .none }

        func field(_ name: String) -> String? {
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\(name) = ") {
                    return String(t.dropFirst(name.count + 3))
                }
            }
            return nil
        }

        let pid = field("pid").flatMap { pid_t($0) }
        return JobState(present: true,
                        pid: pid,
                        runningExecutable: pid.flatMap(executablePath(ofPID:)),
                        managedBy: field("managed_by"),
                        lastExitCode: field("last exit code"))
    }

    /// The absolute path a running process was executed from.
    ///
    /// Measured to work across processes of the same user with no entitlement and no
    /// privilege. `ps -o comm=` is not a substitute — it prints `micpeg`, with no path.
    static func executablePath(ofPID pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }

    // MARK: - Reporting

    /// Every line the survey has, for the transcript and for docs/verification.md. The
    /// numbers and paths are the evidence; the verdict above is only a reading of them.
    func lines() -> [String] {
        var out: [String] = []
        out.append("bundle:            \(bundleURL.path)")
        out.append("bundled daemon:    \(FileManager.default.isExecutableFile(atPath: bundledDaemon.path) ? "present" : "MISSING") — \(bundledDaemon.path)")
        out.append("legacy plist:      \(legacyPlistExists ? "PRESENT" : "absent") — \(legacyPlist.path)")
        if let program = legacyProgram {
            out.append("  its program:     \(program)")
        }
        out.append("  statusForLegacyPlist: \(AgentController.describe(legacyAPIStatus))"
                   + "   (recorded, not trusted — see the header of InstallSurvey.swift)")
        out.append("launchd job:       \(job.present ? "present" : "none") — \(Self.serviceTarget)")
        if job.present {
            out.append("  pid:             \(job.pid.map(String.init) ?? "none (nothing running)")")
            out.append("  running from:    \(job.runningExecutable?.path ?? "unknown — no pid to ask")")
            out.append("  managed_by:      \(job.managedBy ?? "(absent — not an SMAppService job)")")
            out.append("  last exit code:  \(job.lastExitCode ?? "(none)")")
        }
        out.append("SMAppService:      \(AgentController.describe(serviceStatus))")
        out.append("CLI on PATH:       \(cli.description) — \(cliPath.path)")
        out.append("state.json:        \(stateUpdated.map { DaemonState.stamp.string(from: $0) } ?? "never written")")
        if let recorded = registeredFrom {
            out.append("registered from:   \(recorded.bundlePath)"
                       + (hasMoved ? "   — NOT where this app is now" : "")
                       + (recorded.at.map { ", at \(DaemonState.stamp.string(from: $0))" } ?? ""))
        } else {
            out.append("registered from:   (no record — this app has not registered on this"
                       + " machine, or the preference was cleared. Absence proves nothing.)")
        }
        out.append("verdict:           \(verdictName) — \(explanation)")
        return out
    }

    var verdictName: String {
        switch verdict {
        case .healthy:          return "HEALTHY"
        case .moved:            return "MOVED"
        case .legacyPresent:    return "LEGACY PRESENT"
        case .foreignBundle:    return "FOREIGN BUNDLE"
        case .stale:            return "STALE"
        case .requiresApproval: return "REQUIRES APPROVAL"
        case .notRegistered:    return "NOT REGISTERED"
        }
    }
}
