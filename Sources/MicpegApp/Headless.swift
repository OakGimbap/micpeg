// A terminal front end to the same SMAppService calls the window makes.
//
// Stage 2 exists to settle the assumptions docs/app-design.md lists as unobserved, and an
// assumption settled by clicking a button and reporting what the window said is weaker
// evidence than one settled by a command whose output can be pasted into
// docs/verification.md and run again. So every operation the harness window offers is also
// reachable as an argument:
//
//   Micpeg.app/Contents/MacOS/MicpegApp status
//   Micpeg.app/Contents/MacOS/MicpegApp register | unregister | reregister
//   Micpeg.app/Contents/MacOS/MicpegApp survey | migrate | repair | link
//
// The second line is stage 2's: raw SMAppService calls, nothing else. The third is stage 3's
// and answers a different question — not "what did ServiceManagement return" but "what is
// actually installed on this machine and what is running". `survey` changes nothing.
//
// Bundle.main still resolves to the enclosing .app when the executable is invoked by path,
// so this exercises the same registration the GUI would — that is worth stating because the
// CLI's own bundle guard exists precisely because Bundle.main is *not* reliable for the
// reverse question ("am I inside a bundle") when reached through a PATH symlink. Here the
// path is direct.
//
// This file is part of the stage 2 harness and is expected to be deleted at stage 4.

import Foundation
import ServiceManagement

enum Headless {
    /// Runs the requested operation and never returns if there was one.
    static func runIfRequested() {
        guard let command = CommandLine.arguments.dropFirst().first else { return }

        let service = SMAppService.agent(plistName: AgentController.plistName)
        report("bundle: \(Bundle.main.bundleURL.path)")
        report("BundleProgram target: \(AgentController.bundleProgramReport())")
        report("status before: \(AgentController.describe(service.status))")

        var failed = false
        switch command {
        case "status":
            break

        // MARK: stage 3

        case "survey":
            // Read-only. Everything the app can learn without touching anything.
            let survey = InstallSurvey.take()
            report("")
            survey.lines().forEach(report)
            failed = !survey.verdict.isHealthy

        case "migrate":
            // Tear down the legacy LaunchAgent if there is one, then register this bundle.
            let outcome = Migration.migrate()
            report("")
            outcome.lines.forEach(report)
            failed = !outcome.ok

        case "repair":
            // unregister() then register(), for a registration that no longer resolves here.
            let outcome = Migration.repair()
            report("")
            outcome.lines.forEach(report)
            failed = !outcome.ok

        case "link":
            // Replace ~/.local/bin/micpeg with a symlink into this bundle. Explicit on
            // purpose: it is the user's file, and the migration only ever offers this.
            let outcome = Migration.linkCLI()
            report("")
            outcome.lines.forEach(report)
            failed = !outcome.ok

        case "register":
            failed = !attempt("register()") { try service.register() }

        case "unregister":
            failed = !attempt("unregister()") { try service.unregister() }

        case "reregister":
            // SMAppService.h: after the executable inside the bundle changes the service
            // "must be re-registered", and the completion handler is what tells us the old
            // process is gone and "it is safe to re-register the service".
            let done = DispatchSemaphore(value: 0)
            service.unregister { error in
                if let error {
                    report("unregister(completionHandler:): \(AgentController.describe(error))")
                } else {
                    report("unregister(completionHandler:): no error")
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 10) == .timedOut {
                report("unregister(completionHandler:): TIMED OUT after 10s")
                failed = true
            }
            failed = !attempt("register()") { try service.register() } || failed

        default:
            FileHandle.standardError.write(Data(
                "usage: MicpegApp [status|register|unregister|reregister|survey|migrate|repair|link]\n".utf8))
            exit(2)
        }

        // Read the status again rather than inferring it from the call. A register() that
        // returns without throwing and leaves the service at .requiresApproval is the
        // silent success CLAUDE.md names as one of this app's failure modes.
        let after = service.status
        report("")
        report("status after:  \(AgentController.describe(after))")
        // The stage 3 commands have already reported a verdict drawn from more than this
        // status, and stage 2 measured that `.enabled` can be true of somebody else's agent.
        // Do not overwrite their answer with this one.
        let judgedBySMAppServiceAlone = ["status", "register", "reregister"].contains(command)
        if judgedBySMAppServiceAlone, after != .enabled {
            report("NOT ENABLED — launchd will not run the agent in this state.")
            failed = true
        }
        exit(failed ? 1 : 0)
    }

    private static func attempt(_ label: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            report("\(label): returned without throwing")
            return true
        } catch {
            report("\(label): threw \(AgentController.describe(error))")
            return false
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
