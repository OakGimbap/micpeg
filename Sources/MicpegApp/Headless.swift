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
                "usage: MicpegApp [status|register|unregister|reregister]\n".utf8))
            exit(2)
        }

        // Read the status again rather than inferring it from the call. A register() that
        // returns without throwing and leaves the service at .requiresApproval is the
        // silent success CLAUDE.md names as one of this app's failure modes.
        let after = service.status
        report("status after:  \(AgentController.describe(after))")
        if command != "unregister", after != .enabled {
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
