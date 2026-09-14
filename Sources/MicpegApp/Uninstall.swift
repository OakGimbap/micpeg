// Removing Micpeg, from inside Micpeg.
//
// docs/app-design.md: "Stage 5's uninstall instructions cannot be 'drag it to the Trash' alone."
// The evidence is measured, in docs/verification.md §3 and §28: deleting the app leaves the daemon
// running on the inode it already holds, leaves a launchd job nothing will ever spawn again, and —
// on macOS 26.6 — leaves the Background Task Management record and its Login Items entry exactly
// where they were, whether the app was moved, dragged to the Trash, or the Trash was emptied. A
// user who removes Micpeg the obvious way is left with a switch in System Settings for an app that
// no longer exists.
//
// Only `SMAppService.unregister()` clears that record, so only the app can do this. It cannot be a
// `micpeg` subcommand: scripts/invariants.sh holds the daemon's imports to CoreAudio, Darwin,
// Foundation and MicpegAudio, so the CLI can never call ServiceManagement — and `cmdUninstall`
// already refuses outright from inside a bundle, which is the guard that keeps one label to one
// registration path.
//
// Order is the same shape as Migration.tearDownLegacy: stop the thing first, then prove it, then
// remove what it owned. Deleting config.json under a live daemon makes it log "settings
// unreadable" and write state.json straight back.
//
// What is deliberately *not* here: the app bundle. scripts/invariants.sh forbids `trashItem` in
// the app, and a process deleting the executable it is running from is a bad idea independent of
// any rule. The last step reveals the bundle in the Finder and quits, which the confirmation
// dialog says up front.

import AppKit
import Foundation
import MicpegUI
import ServiceManagement

enum Uninstall {

    /// Tear down everything this Mac holds for Micpeg except the bundle itself.
    ///
    /// Returns the same `Migration.Outcome` every other operation does, so it reports through
    /// `AgentController.report(_:label:)` into the unified log and ends with a fresh survey rather
    /// than with an opinion.
    static func run() -> Migration.Outcome {
        var lines: [String] = []
        var ok = true
        let fm = FileManager.default
        let before = InstallSurvey.take()
        lines.append("before: \(before.verdictName)")

        // 1. The registration, waited for. The synchronous form does not wait for the service to
        //    be reaped, and everything below assumes the daemon is gone.
        let (unregistered, timedOut) = AgentController.unregisterAndWait()
        lines.append(unregistered)
        if timedOut {
            lines.append("  (the unregister did not complete in time; continuing, because the"
                       + " survey at the end is what says whether it worked)")
        }

        // 2. Whatever launchd still holds. Stage 2 measured that a job can outlive the record, and
        //    that `unregister()`'s return value is not evidence — `launchctl print` is.
        let after = InstallSurvey.take()
        if after.job.present {
            let (status, output) = runTool("/bin/launchctl",
                                           ["bootout", InstallSurvey.serviceTarget])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("launchctl bootout \(InstallSurvey.serviceTarget) → status \(status)"
                         + (trimmed.isEmpty ? "" : " — \(trimmed)"))
        } else {
            lines.append("no launchd job under the label after unregistering")
        }

        // 3. The legacy plist, if this Mac ever had the command-line install. Left behind it is
        //    not inert: §8 measured it switching a registration back on within a second.
        if fm.fileExists(atPath: before.legacyPlist.path) {
            ok = remove(before.legacyPlist, "the command-line install's LaunchAgent", &lines) && ok
        }

        // 4. The daemon's files. The directory only if it is then empty — it is under the user's
        //    home and nothing here is entitled to delete something a person put there.
        for file in [DaemonPaths.config, DaemonPaths.state] where fm.fileExists(atPath: file.path) {
            ok = remove(file, "settings", &lines) && ok
        }
        let leftovers = (try? fm.contentsOfDirectory(atPath: DaemonPaths.directory.path)) ?? []
        if leftovers.isEmpty, fm.fileExists(atPath: DaemonPaths.directory.path) {
            ok = remove(DaemonPaths.directory, "the now-empty settings directory", &lines) && ok
        } else if !leftovers.isEmpty {
            lines.append("kept \(DaemonPaths.directory.path): it holds"
                       + " \(leftovers.count) other file(s) nothing here put there")
        }

        // 5. The log.
        if fm.fileExists(atPath: DaemonPaths.log.path) {
            ok = remove(DaemonPaths.log, "the log", &lines) && ok
        }

        // 6. The CLI on PATH — only when it is this bundle's own symlink. A regular file there is
        //    the standalone install, which is the user's, and Migration.swift states the rule:
        //    replacing a binary the user installed themselves, unasked, is how an upgrade silently
        //    breaks a working setup. Removing it unasked is the same mistake with a worse ending.
        switch before.cli {
        case .symlink:
            ok = remove(before.cliPath, "the link to this bundle's micpeg", &lines) && ok
        case .regularFile:
            lines.append("kept \(before.cliPath.path): it is a copy of the command-line tool,"
                       + " installed separately, not a link into this bundle")
        case .absent, .other:
            lines.append("nothing to remove at \(before.cliPath.path) (\(before.cli.description))")
        }

        // 7. The app's own two stored values, each cleared by the file that owns it. These are the
        //    only two, and scripts/invariants.sh is what keeps that true.
        RegistrationRecord.clear()
        AppLanguage.choose(nil)
        lines.append("cleared the registration record and the chosen language")

        // 8. Prove it. `ok` above only says every call returned; this says what is actually left.
        let final = InstallSurvey.take()
        lines.append("after: \(final.verdictName), launchd job \(final.job.present ? "present" : "gone"), SMAppService \(AgentController.describe(final.serviceStatus))")
        if final.job.present || final.legacyPlistExists {
            lines.append("FAILED: something under the label survived removal.")
            ok = false
        }
        return Migration.Outcome(ok: ok, lines: lines, survey: final)
    }

    /// Show the user where the bundle is, and get out of the way. Called after `run()` reports, so
    /// a failure has already been seen — there is no state left worth keeping the app open for.
    @MainActor
    static func revealAndQuit() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    private static func remove(_ url: URL, _ what: String, _ lines: inout [String]) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            lines.append("removed \(what): \(url.path)")
            return true
        } catch {
            lines.append("FAILED to remove \(what) at \(url.path): \(error)")
            return false
        }
    }
}
