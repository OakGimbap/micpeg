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
//   Micpeg.app/Contents/MacOS/MicpegApp meter [seconds]
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
// Written as part of the stage 2 harness and expected to be deleted at stage 4. That
// prediction was wrong and the file stays: stage 3 turned `survey` into the diagnostic this
// project actually reaches for, and CLAUDE.md now documents it as the development workflow.
// The harness *window* is gone — MicpegUI replaced it — but a diagnostic that can be pasted
// into docs/verification.md and run again is worth more than one that needs a mouse.

import Foundation
import MicpegUI
import ServiceManagement

enum Headless {
    /// Runs the requested operation and never returns if there was one.
    /// The verbs this front end answers to. Membership is checked before anything else
    /// because `runIfRequested()` is called from `App.init()`: treating *any* first argument
    /// as a command meant an argument the system or a launcher injects — Xcode's
    /// `-NSDocumentRevisionsDebugMode`, or `open --args -AppleLanguages '("ko")'`, which the
    /// planned Korean localization makes likely — exited the process with status 2 before a
    /// window existed, with nothing on screen to say why.
    static let verbs: Set<String> = ["status", "survey", "migrate", "repair", "link", "meter",
                                     "register", "unregister", "reregister"]

    static func runIfRequested() {
        guard let command = CommandLine.arguments.dropFirst().first,
              verbs.contains(command) else { return }

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

        case "meter":
            // Stage 4. The level meter is the only custom-drawn element, and a bar that never
            // moves looks the same as a muted microphone. This prints the numbers behind it.
            let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? 5
            failed = !runMeter(seconds: seconds)

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
            // Unreachable: `verbs` gates the entry. Kept so adding a verb to the set without
            // adding a case here fails loudly rather than falling through to "status".
            FileHandle.standardError.write(Data(
                "MicpegApp: \(command) is in the verb set but has no implementation\n".utf8))
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

    /// Runs the same tap the meter uses and prints a summary rather than a stream, because
    /// what matters is whether anything arrived at all and how loud it was.
    private static func runMeter(seconds: Double) -> Bool {
        report("opening the default input for \(seconds)s — this uses the microphone")
        let samples = Locked<[Float]>([])
        let finished = DispatchSemaphore(value: 0)
        let failure = Locked<String?>(nil)
        InputTest.measure(seconds: seconds, report: { value in
            samples.withValue { $0.append(value) }
        }) { error in
            failure.set(error)
            finished.signal()
        }
        if finished.wait(timeout: .now() + seconds + 10) == .timedOut {
            report("TIMED OUT waiting for the tap to finish")
            return false
        }
        if let message = failure.get() {
            report("FAILED: \(message)")
            return false
        }
        let values = samples.get()
        let count = values.count
        let peak = values.max() ?? 0
        let mean = count == 0 ? 0 : values.reduce(0, +) / Float(count)
        report("buffers:  \(count)")
        report("peak RMS: \(String(format: "%.5f", peak))")
        report("mean RMS: \(String(format: "%.5f", mean))")
        if count == 0 {
            report("NOTHING ARRIVED — the tap was installed and never called. That is not a"
                 + " quiet room; it is a stream that is not running.")
            return false
        }
        // Reported in the window's own units so the two cannot drift: the meter's floor and
        // the "no sound" line are the same number.
        report(InputTest.level(fromRMS: peak) > 0
               ? "audio is reaching the microphone (the meter's floor is"
                 + " \(InputTest.floorDB) dBFS)"
               : "everything is at or below the meter's \(InputTest.floorDB) dBFS floor — the"
                 + " window would say \"No sound is reaching this microphone\"")
        return true
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
