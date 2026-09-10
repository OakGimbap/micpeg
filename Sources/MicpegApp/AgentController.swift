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
//      reregister() exists and why it uses the completion-handler form: the header says the
//      handler runs after the old process has been killed, and only then "it is safe to
//      re-register the service".
//
// register() returning without throwing is not evidence that the agent runs. The header is
// explicit that a registered service can still be sitting at .requiresApproval, and
// CLAUDE.md lists exactly that as one of this app's silent failures. So every operation in
// this file ends by reading `status` again and recording what it read.

import Foundation
import ServiceManagement

@MainActor
@Observable
final class AgentController {
    /// The file name inside Contents/Library/LaunchAgents. The label inside that plist stays
    /// `com.micpeg.agent` on purpose — see docs/app-design.md, "The label stays".
    nonisolated static let plistName = "com.micpeg.agent.plist"

    struct Entry: Identifiable {
        let id = UUID()
        let at = Date()
        let text: String
    }

    private let service = SMAppService.agent(plistName: AgentController.plistName)

    private(set) var status: SMAppService.Status
    private(set) var transcript: [Entry] = []

    /// What is installed on this machine, as of the last look. Stage 3: `status` alone was
    /// never enough — it is keyed on the label, so it answers for whichever agent holds that
    /// label, including a legacy one this app did not register.
    private(set) var survey: InstallSurvey
    /// Set while a migration or repair is running, so the harness can stop a second one being
    /// started underneath the first.
    private(set) var busy = false

    init() {
        status = service.status
        survey = InstallSurvey.take()
        note("launched: status = \(Self.describe(status))")
        note("bundle: \(Bundle.main.bundleURL.path)")
        note("BundleProgram target: \(Self.bundleProgramReport())")
        note("survey: \(survey.verdictName) — \(survey.explanation)")
    }

    // MARK: - Operations

    func refresh() {
        status = service.status
        survey = InstallSurvey.take()
        note("refresh: status = \(Self.describe(status)), survey = \(survey.verdictName)")
    }

    // MARK: - Stage 3

    /// Read everything, change nothing.
    func takeSurvey() {
        survey = InstallSurvey.take()
        note("survey:")
        survey.lines().forEach { note("  " + $0) }
    }

    /// Tear down the legacy LaunchAgent if there is one, then register this bundle.
    func migrate() { run("migrate") { Migration.migrate() } }

    /// unregister() then register(), for a registration that no longer resolves here.
    func repair() { run("repair") { Migration.repair() } }

    /// Offer only — see Migration.linkCLI(). Never called on the app's own initiative.
    func linkCLI() { run("link") { Migration.linkCLI() } }

    /// These block: they wait on launchd, on a completion handler, and on the daemon writing
    /// its state file. None of that belongs on the main actor, and a window that stops
    /// redrawing while it happens would hide exactly the delay worth seeing.
    private func run(_ label: String, _ body: @escaping @Sendable () -> Migration.Outcome) {
        guard !busy else { return }
        busy = true
        note("\(label): started")
        Task.detached(priority: .userInitiated) {
            let outcome = body()
            await MainActor.run {
                outcome.lines.forEach { self.note("  " + $0) }
                self.note("\(label): \(outcome.ok ? "ok" : "DID NOT REACH A HEALTHY STATE")")
                self.survey = outcome.survey
                self.status = self.service.status
                self.busy = false
            }
        }
    }

    func register() {
        do {
            try service.register()
            note("register(): returned without throwing")
        } catch {
            note("register(): threw \(Self.describe(error))")
        }
        refresh()
        warnIfRegisteredButNotEnabled()
    }

    func unregister() {
        do {
            try service.unregister()
            note("unregister(): returned without throwing")
        } catch {
            note("unregister(): threw \(Self.describe(error))")
        }
        refresh()
    }

    /// Unregister, wait for the old process to be reaped, then register again.
    ///
    /// This is the sequence SMAppService.h prescribes after the executable inside the bundle
    /// has changed. Doing it as two independent button presses would race: the synchronous
    /// `unregister()` "will not wait for the service to be reaped".
    func reregister() {
        note("reregister(): unregistering, then registering once the old process is gone")
        service.unregister { error in
            Task { @MainActor in
                if let error {
                    // kSMErrorJobNotFound here just means it was not registered to begin
                    // with, which is not a reason to skip the register below.
                    self.note("  unregister completion: \(Self.describe(error))")
                } else {
                    self.note("  unregister completion: no error")
                }
                self.register()
            }
        }
    }

    func openLoginItems() {
        note("openSystemSettingsLoginItems()")
        SMAppService.openSystemSettingsLoginItems()
    }

    func copyTranscript() -> String {
        transcript.map { "\(Self.stamp.string(from: $0.at))  \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Reporting

    private func warnIfRegisteredButNotEnabled() {
        switch status {
        case .enabled:
            break
        case .requiresApproval:
            note("  NOTE: registered, but launchd will not run it until it is enabled in"
                 + " System Settings > General > Login Items & Extensions.")
        case .notRegistered, .notFound:
            note("  NOTE: register() reported success but the status is"
                 + " \(Self.describe(status)). Treat this as a failure, not as something"
                 + " to retry silently.")
        @unknown default:
            break
        }
    }

    private func note(_ text: String) {
        transcript.append(Entry(text: text))
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated static func describe(_ status: SMAppService.Status) -> String {
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
    nonisolated static func describe(_ error: Error) -> String {
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
    nonisolated private static func smErrorName(_ code: Int) -> String? {
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
    nonisolated static func bundleProgramReport() -> String {
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
