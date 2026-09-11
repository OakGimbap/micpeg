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
//   Micpeg.app/Contents/MacOS/MicpegApp activity [--log <path>]
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
import MicpegAudio
import MicpegUI
import ServiceManagement

enum Headless {
    /// The verbs this front end answers to. Membership is checked before anything else
    /// because `runIfRequested()` is called from `App.init()`: treating *any* first argument
    /// as a command meant an argument the system or a launcher injects — Xcode's
    /// `-NSDocumentRevisionsDebugMode`, or `open --args -AppleLanguages '("ko")'`, which the
    /// planned Korean localization makes likely — exited the process with status 2 before a
    /// window existed, with nothing on screen to say why.
    ///
    /// An enum, so the compiler checks that every verb accepted has an implementation. It was
    /// a set of strings beside a `switch`, and a `default:` that could only fail at run time.
    enum Verb: String {
        case status, survey, migrate, repair, link, meter
        case register, unregister, reregister
        case activity

        /// `activity` has nothing to do with registration, so it gets none of the
        /// SMAppService reporting: two round trips to backgroundtaskmanagementd to print a
        /// status nobody asked about.
        var reportsRegistration: Bool { self != .activity }

        /// Whether SMAppService's status is the whole verdict. The stage 3 commands have
        /// already reported one drawn from more than it, and stage 2 measured that `.enabled`
        /// can be true of somebody else's agent — theirs must not be overwritten with this.
        var judgedByStatusAlone: Bool { [.status, .register, .reregister].contains(self) }
    }

    /// Runs the requested operation and never returns if there was one.
    static func runIfRequested() {
        guard let argument = CommandLine.arguments.dropFirst().first,
              let verb = Verb(rawValue: argument) else { return }

        let service = AgentController.service
        if verb.reportsRegistration {
            report("bundle: \(Bundle.main.bundleURL.path)")
            report("BundleProgram target: \(AgentController.bundleProgramReport())")
            report("status before: \(AgentController.describe(service.status))")
        }

        var failed = false
        switch verb {
        case .status:
            break

        // MARK: stage 3

        case .survey:
            // Read-only. Everything the app can learn without touching anything.
            let survey = InstallSurvey.take()
            report("")
            survey.lines().forEach(report)
            failed = !survey.verdict.isHealthy

        case .migrate:
            // Tear down the legacy LaunchAgent if there is one, then register this bundle.
            failed = !show(Migration.migrate())

        case .repair:
            // unregister() then register(), for a registration that no longer resolves here.
            failed = !show(Migration.repair())

        case .meter:
            // Stage 4. The level meter is the only custom-drawn element, and a bar that never
            // moves looks the same as a muted microphone. This prints the numbers behind it.
            let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? 5
            failed = !runMeter(seconds: seconds)

        case .activity:
            failed = !runActivity()

        case .link:
            // Replace ~/.local/bin/micpeg with a symlink into this bundle. Explicit on
            // purpose: it is the user's file, and the migration only ever offers this.
            failed = !show(Migration.linkCLI())

        case .register:
            failed = !attempt("register()") { try service.register() }

        case .unregister:
            failed = !attempt("unregister()") { try service.unregister() }

        case .reregister:
            // SMAppService.h: after the executable inside the bundle changes the service
            // "must be re-registered" — after an unregister that has been waited out.
            let (line, timedOut) = AgentController.unregisterAndWait()
            report(line)
            failed = !attempt("register()") { try service.register() } || timedOut
        }

        if verb.reportsRegistration {
            // Read the status again rather than inferring it from the call. A register() that
            // returns without throwing and leaves the service at .requiresApproval is the
            // silent success CLAUDE.md names as one of this app's failure modes.
            let after = service.status
            report("")
            report("status after:  \(AgentController.describe(after))")
            if verb.judgedByStatusAlone, after != .enabled {
                report("NOT ENABLED — launchd will not run the agent in this state.")
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }

    /// An operation's transcript, after a blank line. True when it reached what it set out to.
    private static func show(_ outcome: Migration.Outcome) -> Bool {
        report("")
        outcome.lines.forEach(report)
        return outcome.ok
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

    /// The Activity window's rows as text — the same parse, the same day headers and time
    /// labels, and the sentence VoiceOver reads — so the classification can be checked against
    /// the real log, or against a fixture holding the failure lines no hardware session can be
    /// made to produce, without a window or a mouse.
    ///
    /// Device names appear in the output. Paste shapes and counts into docs/verification.md,
    /// never names.
    private static func runActivity() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst(2))
        var url = DaemonPaths.log
        if let flag = args.firstIndex(of: "--log"), flag + 1 < args.count {
            url = URL(fileURLWithPath: args[flag + 1])
        }
        var target = Copy.noDevice
        if case .ok(let config) = PinnedConfig.read(), let name = config.targetName {
            target = name
        }
        let started = Date()
        let rows = ActivityLog.recent(from: url)
        let elapsed = Date().timeIntervalSince(started) * 1000
        report("log: \(url.path)")
        report("\(rows.count) rows, parsed in \(String(format: "%.1f", elapsed)) ms")
        let now = Date()
        for day in ActivityTime.days(rows, now: now) {
            report("")
            report(day.title)
            for row in day.entries {
                let time = ActivityTime.label(for: row.at, now: now)
                let count = row.count > 1 ? " \(Copy.repeatCount(row.count))" : ""
                report("  " + time.padding(toLength: 11, withPad: " ", startingAt: 0)
                     + "\(row.actor)".padding(toLength: 8, withPad: " ", startingAt: 0)
                     + describe(row.kind) + count)
                report("               " + Copy.accessibilitySentence(for: row, target: target))
            }
        }
        return true
    }

    private static func describe(_ kind: Activity.Kind) -> String {
        func name(_ device: Activity.Device?) -> String {
            guard let device else { return "·" }
            return device.name + (device.transport.map { " [\(fourCC($0))]" } ?? "")
        }
        switch kind {
        case .restored(let to, let from): return "restored     \(name(from)) → \(name(to))"
        case .chose(let to, let from):    return "chose        \(name(from)) → \(name(to))"
        case .switchedAway(let to):       return "switchedAway → \(name(to))"
        case .switchedBack:               return "switchedBack"
        case .paused:                     return "paused"
        case .resumed(let to, let from):  return "resumed      \(name(from)) → \(name(to))"
        case .started:                    return "started"
        case .reconnected:                return "reconnected"
        case .backInUse:                  return "backInUse"
        case .disconnected:               return "disconnected"
        case .backedOff:                  return "backedOff"
        case .problem(let problem):       return "problem      \(problem)"
        }
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
