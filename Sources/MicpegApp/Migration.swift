// Stage 3: taking over from the hand-written LaunchAgent, and repairing a registration that
// has come loose from this bundle.
//
// The order is the one in docs/app-design.md and it is not interchangeable. The legacy
// LaunchAgent and the bundled agent share the label `com.micpeg.agent`, and stage 2 measured
// what that means: with the legacy agent running, `register()` returns without throwing,
// writes no Background Task Management record, and `status` then reports `.enabled` — about
// the legacy agent. Registering first and cleaning up afterwards would therefore look like a
// complete success and leave the user's microphone pinned by a daemon this app cannot see,
// cannot update, and will not remove when it is uninstalled. Tear down first.
//
// Nothing here trusts a return value. `unregister()` "also does nothing at all when status is
// .notFound", `register()` can succeed into `.requiresApproval`, and `launchctl bootout`
// returns non-zero for a job that was already gone. So every operation ends with a fresh
// InstallSurvey, and success means the survey says so: the plist is off disk, a pid exists,
// proc_pidpath puts that pid inside this bundle, and the daemon has written state.json since
// the operation began.
//
// The migration deliberately does not touch:
//   - ~/.config/micpeg/config.json — the pinned device survives the upgrade, which is the
//     whole reason the config was left where the daemon already looks for it.
//   - ~/.config/micpeg/state.json — a stale state file is evidence that the new daemon has
//     not written yet, and the freshness check below depends on being able to see that.
//   - ~/.local/bin/micpeg — replacing a binary the user installed themselves, unasked, is
//     how an upgrade silently breaks a working setup. It is offered, never taken.

import Foundation
import ServiceManagement

enum Migration {

    struct Outcome {
        let ok: Bool
        let lines: [String]
        let survey: InstallSurvey
    }

    /// How long to wait for launchd to spawn the agent after registering.
    ///
    /// RunAtLoad makes the first spawn immediate; this is slack, not a duty cycle. It is not
    /// ThrottleInterval — a job that has already run once inside the last 60s sits at
    /// "spawn scheduled" and no amount of waiting here changes that, which is exactly why
    /// the failure message below says what it says.
    private static let spawnTimeout: TimeInterval = 20

    // MARK: - The documented flow

    /// Tear down the legacy install if there is one, then register this bundle's agent.
    static func migrate() -> Outcome {
        var lines: [String] = []
        let before = InstallSurvey.take()
        lines.append("--- before ---")
        lines += before.lines()

        if before.legacyPlistExists {
            lines.append("--- tearing down the legacy LaunchAgent ---")
            lines += tearDownLegacy(before)
        } else {
            lines.append("--- no legacy LaunchAgent on disk; nothing to tear down ---")
        }

        lines.append("--- registering this bundle ---")
        lines += registerAndConfirm(replacing: before.job.pid)

        let after = InstallSurvey.take()
        lines.append("--- after ---")
        lines += after.lines()
        if case .healthy = after.verdict {} else {
            lines.append("RESULT: NOT healthy — \(after.explanation)")
        }
        lines += cliAdvice(after)
        return Outcome(ok: after.verdict.isHealthy, lines: lines, survey: after)
    }

    /// `unregister()` then `register()`, for a registration that no longer resolves to this
    /// bundle. Stage 2 measured why a bare `register()` is not enough: over a purged record it
    /// creates a new Background Task Management entry while leaving the old launchd job in
    /// place, and the next spawn fails with EX_CONFIG.
    static func repair() -> Outcome {
        var lines: [String] = []
        let before = InstallSurvey.take()
        lines.append("--- before ---")
        lines += before.lines()

        if before.serviceStatus == .requiresApproval {
            lines.append("refusing to repair: the item is switched off in Login Items."
                       + " Measured in stage 2 — register() throws \"Operation not permitted\""
                       + " and unregister-then-register snaps straight back. Only the user can"
                       + " undo this, in System Settings.")
            return Outcome(ok: false, lines: lines, survey: before)
        }

        lines.append("--- unregister, wait for the old process, register ---")
        // SMAppService.h prescribes this after the executable inside the bundle changes: the
        // completion handler runs once the old process has been killed, and only then "it is
        // safe to re-register the service". The synchronous unregister() "will not wait for
        // the service to be reaped", so two separate calls would race.
        let svc = service
        let done = DispatchSemaphore(value: 0)
        var completionError: Error?
        svc.unregister { error in
            completionError = error
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            lines.append("unregister(completionHandler:): TIMED OUT after 10s")
        } else if let completionError {
            // kSMErrorJobNotFound here means it was not registered to begin with, which is
            // not a reason to skip the register below.
            lines.append("unregister(completionHandler:): \(AgentController.describe(completionError))")
        } else {
            lines.append("unregister(completionHandler:): no error")
        }

        lines += registerAndConfirm(replacing: before.job.pid)

        let after = InstallSurvey.take()
        lines.append("--- after ---")
        lines += after.lines()
        return Outcome(ok: after.verdict.isHealthy, lines: lines, survey: after)
    }

    // MARK: - Pieces

    private static var service: SMAppService {
        SMAppService.agent(plistName: AgentController.plistName)
    }

    /// `launchctl bootout`, then remove the plist, then prove both.
    ///
    /// bootout first. Removing the plist while the job is still bootstrapped leaves launchd
    /// holding a job whose definition no longer exists on disk, and the daemon keeps running
    /// on its inode — the same half-torn-down shape stage 2 measured after the app was moved
    /// to the Trash.
    private static func tearDownLegacy(_ before: InstallSurvey) -> [String] {
        var lines: [String] = []

        let (status, output) = InstallSurvey.run("/bin/launchctl",
                                                 ["bootout", InstallSurvey.serviceTarget])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("launchctl bootout \(InstallSurvey.serviceTarget) → status \(status)"
                     + (trimmed.isEmpty ? "" : " — \(trimmed)"))
        if status != 0 {
            lines.append("  (non-zero is not automatically a failure here: bootout returns"
                       + " \"No such process\" for a job that was already gone. The check that"
                       + " matters is the job survey below.)")
        }

        do {
            try FileManager.default.removeItem(at: before.legacyPlist)
            lines.append("removed \(before.legacyPlist.path)")
        } catch {
            lines.append("FAILED to remove \(before.legacyPlist.path): \(error)")
            lines.append("  Registering on top of a legacy plist changes nothing — stage 2"
                       + " measured that. Stopping here rather than reporting a success.")
            return lines
        }

        // Prove it, rather than trusting the two calls above.
        let mid = InstallSurvey.take()
        lines.append("after teardown: legacy plist \(mid.legacyPlistExists ? "STILL PRESENT" : "gone")"
                     + ", launchd job \(mid.job.present ? "still present" : "gone")"
                     + ", SMAppService \(AgentController.describe(mid.serviceStatus))")
        if mid.job.present, let pid = mid.job.pid {
            lines.append("  NOTE: pid \(pid) is still running from"
                       + " \(mid.job.runningExecutable?.path ?? "an unknown path")."
                       + " launchd has let go of the job; the process is on its own inode.")
        }
        return lines
    }

    /// register(), then wait for evidence that a daemon from *this* bundle is running.
    ///
    /// `previousPID` is whatever was running before the operation started. Requiring the new
    /// pid to differ is what stops "it was already fine" from being reported as "we fixed it":
    /// without it, an operation that did nothing at all would confirm itself against the
    /// daemon it was supposed to replace.
    private static func registerAndConfirm(replacing previousPID: pid_t?) -> [String] {
        var out: [String] = []
        let registeredAt = Date()

        do {
            try service.register()
            out.append("register(): returned without throwing")
            // Record the path now rather than after the daemon is confirmed: the question
            // this record answers is where the app was when the registration was created,
            // and register() returning is what creates it.
            RegistrationRecord.write()
            out.append("recorded this bundle as the registration's origin:"
                     + " \(Bundle.main.bundleURL.path)")
        } catch {
            out.append("register(): threw \(AgentController.describe(error))")
            let status = service.status
            out.append("  status is now \(AgentController.describe(status))")
            if status == .requiresApproval {
                out.append("  The item is switched off in Login Items. Nothing this app can"
                         + " call will turn it back on; the user has to.")
            }
            return out
        }

        let status = service.status
        out.append("status after register(): \(AgentController.describe(status))")
        switch status {
        case .enabled:
            break
        case .requiresApproval:
            out.append("  registered, but launchd will not run it until it is enabled in"
                     + " System Settings > General > Login Items & Extensions.")
            return out
        default:
            out.append("  register() reported success and the status is"
                     + " \(AgentController.describe(status)). That is a failure to surface,"
                     + " not something to retry silently.")
            return out
        }

        out += waitForDaemon(since: registeredAt, replacing: previousPID)
        return out
    }

    /// The only honest confirmation: a pid, that pid's executable inside this bundle, and a
    /// state.json the daemon has written since we started. `status == .enabled` proves none
    /// of the three — stage 2 measured it reporting `.enabled` about somebody else's agent.
    private static func waitForDaemon(since start: Date, replacing previousPID: pid_t?) -> [String] {
        var out: [String] = []
        let deadline = Date().addingTimeInterval(spawnTimeout)
        let mine = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/micpeg")
            .resolvingSymlinksInPath()

        var last = InstallSurvey.take()
        while Date() < deadline {
            if let pid = last.job.pid, pid != previousPID,
               let running = last.job.runningExecutable, running == mine,
               let updated = last.stateUpdated, updated > start {
                let waited = Int(Date().timeIntervalSince(start))
                out.append("confirmed after \(waited)s: pid \(pid)"
                         + (previousPID.map { " (was \($0))" } ?? " (nothing was running before)")
                         + " running from \(running.path),"
                         + " state.json written at \(InstallSurvey.stamp.string(from: updated))")
                return out
            }
            Thread.sleep(forTimeInterval: 0.5)
            last = InstallSurvey.take()
        }

        out.append("NOT CONFIRMED within \(Int(spawnTimeout))s:")
        out.append("  pid:            \(last.job.pid.map(String.init) ?? "none")"
                 + (previousPID.map { " (before: \($0))" } ?? ""))
        out.append("  running from:   \(last.job.runningExecutable?.path ?? "unknown")")
        out.append("  expected:       \(mine.path)")
        out.append("  state.json:     \(last.stateUpdated.map { InstallSurvey.stamp.string(from: $0) } ?? "never written")")
        out.append("  last exit code: \(last.job.lastExitCode ?? "(none)")")
        out.append("  A job that has already run once in the last 60s sits at \"spawn"
                 + " scheduled\" because of ThrottleInterval, and EX_CONFIG (78) means launchd"
                 + " could not realise the job at all — most often a program path that is no"
                 + " longer there.")
        return out
    }

    // MARK: - The CLI symlink, offered rather than taken

    private static func cliAdvice(_ survey: InstallSurvey) -> [String] {
        guard survey.cli.isLegacyCopy else { return [] }
        return ["note: \(survey.cliPath.path) is a copy of the old CLI binary, not a link"
              + " into this bundle. It will keep serving the version it was copied from"
              + " through every app update. Replacing it is offered, not automatic — it is"
              + " the user's file."]
    }

    /// Replace the CLI on PATH with a symlink into this bundle, by asking the bundled binary
    /// to do it. `micpeg link` exists for exactly this and refuses a directory; `--force` is
    /// what allows it to replace the legacy copy, and is why this is never called unasked.
    static func linkCLI() -> Outcome {
        var lines: [String] = []
        let daemon = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/micpeg")
        let (status, output) = InstallSurvey.run(daemon.path, ["link", "--force"])
        lines.append("\(daemon.path) link --force → status \(status)")
        for line in output.split(separator: "\n") { lines.append("  \(line)") }

        let after = InstallSurvey.take()
        lines.append("CLI on PATH is now: \(after.cli.description)")
        var ok = status == 0
        if case .symlink(let dest, let resolves) = after.cli {
            if !resolves {
                lines.append("  but nothing is at \(dest.path)")
                ok = false
            }
            let expected = daemon.resolvingSymlinksInPath()
            if dest.resolvingSymlinksInPath() != expected {
                lines.append("  but it points at \(dest.path), not \(expected.path)")
                ok = false
            }
        } else {
            ok = false
        }
        return Outcome(ok: ok, lines: lines, survey: after)
    }
}

extension InstallSurvey.Verdict {
    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}
