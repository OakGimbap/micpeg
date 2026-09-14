// The app's whole relationship with the background agent: one SMAppService, plus a
// transcript of everything it has been asked to do and what actually happened.
//
// Facts here come from the SDK header, not from recollection:
//   MacOSX.sdk/System/Library/Frameworks/ServiceManagement.framework/Headers/SMAppService.h
//
//   - "The plistName must correspond to a plist in the calling app's
//      Contents/Library/LaunchAgents directory"
//   - "plists registered with SMAppService may use the BundleProgram launchd plist key to
//      specify an app bundle relative path for the executable"
//   - "Apps that use SMAppService APIs must be code signed" — and notarization is required
//      for LaunchDaemons only, which is why an agent can be tested with a development
//      signature.
//   - "If an app updates either the plist or the executable ... the SMAppService must be
//      re-registered or it may not launch. It is recommended to also call unregister before
//      re-registering if the executable has been changed."  That last sentence is why
//      unregisterAndWait() exists and why it uses the completion-handler form: the header says
//      the handler runs after the old process has been killed, and only then "it is safe to
//      re-register the service".
//
// register() returning without throwing is not evidence that the agent runs. The header is
// explicit that a registered service can still be sitting at .requiresApproval, and CLAUDE.md
// lists exactly that as one of this app's silent failures. Stage 3 settled where that check
// belongs: Migration.swift re-surveys after every operation and confirms with a pid, that
// pid's executable inside this bundle, and a state.json written after the call. What is left
// here is the pieces that have no better home — the label and plist name, the error and status
// vocabulary, and the operations that are pure ServiceManagement.

import Foundation
import MicpegUI
import os
import ServiceManagement

/// Not a controller any more: a namespace.
///
/// It had an instance side — an `@Observable` transcript of every registration operation —
/// built for the stage 2 harness window's "Copy transcript" button. Stage 4 deleted that
/// window and the transcript became write-only: an `App`-level `@State` object SwiftUI
/// observed, accumulating evidence with no way to read it back. Evidence with no retrieval
/// path is not evidence, so the operations report to the unified log, where
/// `log show --predicate 'subsystem == "com.micpeg.app"'` finds them.
///
/// They went to stderr first, on the belief that `log show` would find that. It does not: the
/// unified log never sees stderr, and an app opened from the Finder has it on /dev/null, so
/// every transcript of every launch repair was discarded.
enum AgentController {
    /// The launchd label — the hand-written LaunchAgent's too, on purpose. See
    /// docs/app-design.md, "The label stays".
    static let label = "com.micpeg.agent"

    /// The file name inside Contents/Library/LaunchAgents — and, since `micpeg install` names
    /// its plist after the label as well, the legacy install's file in ~/Library/LaunchAgents.
    static let plistName = "\(label).plist"

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    private static let log = Logger(subsystem: "com.micpeg.app", category: "registration")

    /// What a migration or repair actually did. The window shows a one-line verdict; this is
    /// the evidence behind it, and why it goes to the unified log is above. One entry a line,
    /// and public: a transcript is paths and verdicts, and a redacted one is no evidence.
    /// The same log, for a condition that is not the outcome of an operation — the one caller is
    /// the install-location guard, which refuses before any operation starts and still has to
    /// leave behind what it saw. The window cannot show it: app-ui.md keeps file paths out of it,
    /// and a translocated path is a randomised one.
    static func report(_ lines: String, label: String) {
        log.notice("\(label, privacy: .public):")
        for line in lines.split(separator: "\n", omittingEmptySubsequences: false) {
            log.notice("  \(String(line), privacy: .public)")
        }
    }

    static func report(_ outcome: Migration.Outcome, label: String) {
        let verdict = outcome.ok ? "reached a healthy state" : "DID NOT reach a healthy state"
        log.notice("\(label, privacy: .public): \(verdict, privacy: .public)")
        for line in outcome.lines {
            log.notice("  \(line, privacy: .public)")
        }
    }

    /// The only correct response to `.requiresApproval`. Measured in stage 2: `register()`
    /// throws "Operation not permitted" there and an unregister-then-register snaps straight
    /// back, so nothing the app can call will undo it. Taking the user to the switch is the
    /// whole remedy — and telling them to "go to System Settings" without taking them there is
    /// where this flow usually dies.
    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// `unregister(completionHandler:)`, waited for — the form the header above prescribes
    /// before registering a changed executable again. The synchronous `unregister()` "will not
    /// wait for the service to be reaped", so a `register()` straight after it would race.
    ///
    /// An error is reported, not treated as failure: kSMErrorJobNotFound means nothing was
    /// registered to begin with, which is no reason to skip the `register()` that follows.
    static func unregisterAndWait() -> (line: String, timedOut: Bool) {
        let done = DispatchSemaphore(value: 0)
        let failure = Locked<Error?>(nil)
        service.unregister { error in
            failure.set(error)
            done.signal()
        }
        let call = "unregister(completionHandler:): "
        if done.wait(timeout: .now() + 10) == .timedOut {
            return (call + "TIMED OUT after 10s", true)
        }
        return (call + (failure.get().map { describe($0) } ?? "no error"), false)
    }

    // MARK: - Reporting

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:     return "notRegistered"
        case .enabled:           return "enabled"
        case .requiresApproval:  return "requiresApproval"
        case .notFound:          return "notFound"
        @unknown default:        return "unknown(\(status.rawValue))"
        }
    }

    /// Print the error whole. The domain ServiceManagement uses has moved across releases
    /// (SMAppServiceErrorDomain is macOS 15+), so the domain string is evidence, not noise,
    /// and the numeric code is matched against SMErrors.h separately rather than assumed.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "domain=\(ns.domain) code=\(ns.code)"
        if let name = smErrorName(ns.code) {
            text += " (\(name), if this is ServiceManagement's domain)"
        }
        text += " — \(ns.localizedDescription)"
        if !ns.userInfo.isEmpty {
            text += " userInfo=\(ns.userInfo)"
        }
        return text
    }

    /// SMErrors.h, in order from kSMErrorInternalFailure = 2.
    private static func smErrorName(_ code: Int) -> String? {
        let names = ["kSMErrorInternalFailure", "kSMErrorInvalidSignature",
                     "kSMErrorAuthorizationFailure", "kSMErrorToolNotValid",
                     "kSMErrorJobNotFound", "kSMErrorServiceUnavailable",
                     "kSMErrorJobPlistNotFound", "kSMErrorJobMustBeEnabled",
                     "kSMErrorInvalidPlist", "kSMErrorLaunchDeniedByUser",
                     "kSMErrorAlreadyRegistered"]
        let index = code - 2
        return names.indices.contains(index) ? names[index] : nil
    }

    /// Whether the executable BundleProgram names is actually there. A missing one is the
    /// failure the case-insensitive-filesystem collision would have produced: the bundle
    /// looks assembled, registration succeeds, and launchd has nothing to exec.
    static func bundleProgramReport() -> String {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(plistName)
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization
                  .propertyList(from: data, format: nil) as? [String: Any] else {
            return "unreadable agent plist at \(plist.path)"
        }
        guard let relative = root["BundleProgram"] as? String else {
            return "agent plist has no BundleProgram key"
        }
        let program = Bundle.main.bundleURL.appendingPathComponent(relative)
        let ok = FileManager.default.isExecutableFile(atPath: program.path)
        return "\(relative) — \(ok ? "present and executable" : "MISSING")"
    }
}
