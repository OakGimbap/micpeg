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
import MicpegUI
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
    ///
    /// `ok` means confirmed — a new pid, from this bundle, with a state.json written since —
    /// and a healthy survey after. It was the survey alone, which the daemon already running
    /// satisfies whether or not anything this did worked.
    static func migrate() -> Outcome {
        var lines: [String] = []
        let before = InstallSurvey.take()
        lines.append("--- before ---")
        lines += before.lines()

        if before.hasLegacyInstall {
            lines.append("--- tearing down the legacy LaunchAgent ---")
            let teardown = tearDownLegacy(before)
            lines += teardown.lines
            guard teardown.done else {
                let after = InstallSurvey.take()
                lines.append("RESULT: NOT healthy — the legacy install is still in place")
                return Outcome(ok: false, lines: lines, survey: after)
            }
        } else {
            lines.append("--- no legacy LaunchAgent; nothing to tear down ---")
        }

        let mid = InstallSurvey.take()
        var confirmed = false
        switch mid.verdict {
        case .healthy:
            // The shape of §8: a legacy plist beside a registration already running from here.
            // Removing the plist was the whole job, and a register() now would start no new
            // daemon for the confirmation to see.
            lines.append("--- already registered here and running; nothing to register ---")
            confirmed = true
        case .foreignBundle(let running):
            lines.append("--- the label is held by another copy of the app, running from"
                       + " \(running.path); not taking it over ---")
        case .requiresApproval:
            // Measured in stage 2: register() throws "Operation not permitted" here, and an
            // unregister first snaps straight back. repair() refuses for the same reason.
            lines.append("--- switched off in Login Items; only the user can turn it back on ---")
        default:
            lines.append("--- registering this bundle ---")
            // The cycle, not a bare register(). verification.md, "One failure that could not be
            // reproduced": the first register() after a legacy uninstall failed with EX_CONFIG,
            // twice, and an unregister() + register() cycle cleared it — "Stage 3 should do that
            // cycle unconditionally". This did a bare register().
            let cycle = reregister(mid)
            lines += cycle.lines
            confirmed = cycle.confirmed
        }

        let after = InstallSurvey.take()
        lines.append("--- after ---")
        lines += after.lines()
        let ok = confirmed && after.verdict.isHealthy
        if !ok {
            lines.append("RESULT: NOT healthy — \(after.explanation)")
        }
        lines += cliAdvice(after)
        return Outcome(ok: ok, lines: lines, survey: after)
    }

    /// `unregister()` then `register()`, for a registration that no longer resolves to this
    /// bundle. Stage 2 measured why a bare `register()` is not enough: over a purged record it
    /// creates a new Background Task Management entry while leaving the old launchd job in
    /// place, and the next spawn fails with EX_CONFIG.
    ///
    /// `ok` is `migrate()`'s: confirmed, and healthy after. The survey alone called a repair
    /// after a Finder move "reconnected" while the confirmation below it said NOT CONFIRMED —
    /// the process it saw was the old one, running on the inode the move carried.
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
        let cycle = reregister(before)
        lines += cycle.lines

        let after = InstallSurvey.take()
        lines.append("--- after ---")
        lines += after.lines()
        return Outcome(ok: cycle.confirmed && after.verdict.isHealthy, lines: lines, survey: after)
    }

    /// `unregister()`, waited out, then `register()` and its confirmation: the one way this app
    /// makes or remakes a registration.
    ///
    /// From `.notFound` with a job still present, a `register()` goes first. Stage 2 measured
    /// both halves of why (§2): an `unregister()` from `.notFound` does nothing — there is no
    /// record for it to act on — and a bare `register()` leaves the old job in place for its next
    /// spawn to fail with EX_CONFIG. The first register gives the unregister a record to remove
    /// that job through: "It only worked after a register() had recreated one." That is the
    /// shape a Finder move leaves, and repair() went straight to the unregister that does nothing.
    private static func reregister(_ before: InstallSurvey) -> (lines: [String], confirmed: Bool) {
        var lines: [String] = []
        if before.serviceStatus == .notFound, before.job.present {
            do {
                try AgentController.service.register()
                lines.append("register() first, from notFound with a job present: returned"
                           + " without throwing")
            } catch {
                lines.append("register() first, from notFound with a job present: threw"
                           + " \(AgentController.describe(error))")
            }
        }
        // A timeout or an error is reported and the register below runs regardless: the
        // confirmation after it is what decides.
        lines.append(AgentController.unregisterAndWait().line)
        let registered = registerAndConfirm(replacing: before.job.pid)
        return (lines + registered.lines, registered.confirmed)
    }

    // MARK: - Pieces

    /// `launchctl bootout`, then remove the plist, then prove both.
    ///
    /// bootout first. Removing the plist while the job is still bootstrapped leaves launchd
    /// holding a job whose definition no longer exists on disk, and the daemon keeps running
    /// on its inode — the same half-torn-down shape stage 2 measured after the app was moved
    /// to the Trash.
    ///
    /// So the plist is removed only once the command-line install's job is gone. It used to be
    /// removed whatever bootout said, and a daemon that outlived a failed bootout then had
    /// nothing on disk to say where it came from — which the survey took for nothing running at
    /// all. And a job ServiceManagement submitted is never booted out: a plist can sit beside a
    /// working registration — the shape of §8, reachable by `micpeg install` from a copy the
    /// bundle guard could not see — and booting the label out there killed the working daemon
    /// to remove a file launchd was ignoring. Which job is which is `managed_by`'s to say, not
    /// the executable's path; `InstallSurvey.legacyJob` says why.
    ///
    /// `done` is false while the install is still in place. `migrate()` stops there rather than
    /// registering on top of it, which stage 2 measured changes nothing; this used to say it was
    /// "stopping here" while `migrate()` carried on.
    private static func tearDownLegacy(_ before: InstallSurvey) -> (lines: [String], done: Bool) {
        var lines: [String] = []

        if before.legacyJob {
            let (status, output) = runTool("/bin/launchctl",
                                           ["bootout", InstallSurvey.serviceTarget])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("launchctl bootout \(InstallSurvey.serviceTarget) → status \(status)"
                         + (trimmed.isEmpty ? "" : " — \(trimmed)"))
            if status != 0 {
                lines.append("  (non-zero is not automatically a failure here: bootout returns"
                           + " \"No such process\" for a job that was already gone. The check"
                           + " that matters is the survey below.)")
            }
            let check = InstallSurvey.take()
            if check.legacyJob {
                lines.append("FAILED: the command-line install's job is still loaded"
                           + (check.job.pid.map { ", pid \($0)," } ?? ",")
                           + " running from \(check.job.runningExecutable?.path ?? "nowhere known")."
                           + " Stopping here, with the plist left in place to say where it"
                           + " came from.")
                return (lines, false)
            }
        } else if before.job.present {
            lines.append("launchd job was submitted by ServiceManagement — a registration, not"
                       + " the command-line install; not booting it out")
        } else {
            lines.append("no launchd job under the label; nothing to boot out")
        }

        if before.legacyPlistExists {
            do {
                try FileManager.default.removeItem(at: before.legacyPlist)
                lines.append("removed \(before.legacyPlist.path)")
            } catch {
                lines.append("FAILED to remove \(before.legacyPlist.path): \(error)")
                lines.append("  Registering on top of a legacy plist changes nothing — stage 2"
                           + " measured that. Stopping here rather than reporting a success.")
                return (lines, false)
            }
        }

        // Prove it, rather than trusting the calls above.
        let mid = InstallSurvey.take()
        lines.append("after teardown: legacy plist \(mid.legacyPlistExists ? "STILL PRESENT" : "gone")"
                     + ", launchd job \(mid.job.present ? "present" : "gone")"
                     + ", SMAppService \(AgentController.describe(mid.serviceStatus))")
        if let pid = mid.job.pid {
            lines.append("  the job's pid \(pid) runs from"
                       + " \(mid.job.runningExecutable?.path ?? "an unknown path")")
        }
        return (lines, true)
    }

    /// register(), then wait for evidence that a daemon from *this* bundle is running.
    ///
    /// `previousPID` is whatever was running before the operation started. Requiring the new
    /// pid to differ is what stops "it was already fine" from being reported as "we fixed it":
    /// without it, an operation that did nothing at all would confirm itself against the
    /// daemon it was supposed to replace.
    private static func registerAndConfirm(replacing previousPID: pid_t?)
        -> (lines: [String], confirmed: Bool) {
        var out: [String] = []
        let registeredAt = Date()

        do {
            try AgentController.service.register()
            out.append("register(): returned without throwing")
            // Record the path now rather than after the daemon is confirmed: the question
            // this record answers is where the app was when the registration was created,
            // and register() returning is what creates it.
            RegistrationRecord.write()
            out.append("recorded this bundle as the registration's origin:"
                     + " \(Bundle.main.bundleURL.path)")
        } catch {
            out.append("register(): threw \(AgentController.describe(error))")
            let status = AgentController.service.status
            out.append("  status is now \(AgentController.describe(status))")
            if status == .requiresApproval {
                out.append("  The item is switched off in Login Items. Nothing this app can"
                         + " call will turn it back on; the user has to.")
            }
            return (out, false)
        }

        let status = AgentController.service.status
        out.append("status after register(): \(AgentController.describe(status))")
        switch status {
        case .enabled:
            break
        case .requiresApproval:
            out.append("  registered, but launchd will not run it until it is enabled in"
                     + " System Settings > General > Login Items & Extensions.")
            return (out, false)
        default:
            out.append("  register() reported success and the status is"
                     + " \(AgentController.describe(status)). That is a failure to surface,"
                     + " not something to retry silently.")
            return (out, false)
        }

        let wait = waitForDaemon(since: registeredAt, replacing: previousPID)
        return (out + wait.lines, wait.confirmed)
    }

    /// The only honest confirmation: a pid, that pid's executable inside this bundle, and a
    /// state.json the daemon has written since we started. `status == .enabled` proves none
    /// of the three — stage 2 measured it reporting `.enabled` about somebody else's agent.
    ///
    /// `confirmed` is what the callers' `ok` rests on. It used to be written into the transcript
    /// and nowhere else.
    private static func waitForDaemon(since start: Date, replacing previousPID: pid_t?)
        -> (lines: [String], confirmed: Bool) {
        var out: [String] = []
        let deadline = Date().addingTimeInterval(spawnTimeout)
        let mine = MicpegCLI.bundledExecutable.resolvingSymlinksInPath()

        var last = InstallSurvey.take()
        while Date() < deadline {
            if let pid = last.job.pid, pid != previousPID,
               let running = last.job.runningExecutable, running == mine,
               let updated = last.stateUpdated, updated > start {
                let waited = Int(Date().timeIntervalSince(start))
                out.append("confirmed after \(waited)s: pid \(pid)"
                         + (previousPID.map { " (was \($0))" } ?? " (nothing was running before)")
                         + " running from \(running.path),"
                         + " state.json written at \(DaemonState.stamp.string(from: updated))")
                return (out, true)
            }
            Thread.sleep(forTimeInterval: 0.5)
            last = InstallSurvey.take()
        }

        out.append("NOT CONFIRMED within \(Int(spawnTimeout))s:")
        out.append("  pid:            \(last.job.pid.map(String.init) ?? "none")"
                 + (previousPID.map { " (before: \($0))" } ?? ""))
        out.append("  running from:   \(last.job.runningExecutable?.path ?? "unknown")")
        out.append("  expected:       \(mine.path)")
        out.append("  state.json:     \(last.stateUpdated.map { DaemonState.stamp.string(from: $0) } ?? "never written")")
        out.append("  last exit code: \(last.job.lastExitCode ?? "(none)")")
        out.append("  A job that has already run once in the last 60s sits at \"spawn"
                 + " scheduled\" because of ThrottleInterval, and EX_CONFIG (78) means launchd"
                 + " could not realise the job at all — most often a program path that is no"
                 + " longer there.")
        return (out, false)
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
        let daemon = MicpegCLI.bundledExecutable
        let (status, output) = runTool(daemon.path, ["link", "--force"])
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
