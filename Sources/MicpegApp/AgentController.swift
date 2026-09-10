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
// explicit that a registered service can still be sitting at .requiresApproval, and CLAUDE.md
// lists exactly that as one of this app's silent failures. Stage 3 settled where that check
// belongs: Migration.swift re-surveys after every operation and confirms with a pid, that
// pid's executable inside this bundle, and a state.json written after the call. What is left
// here is the pieces that have no better home — the plist name, the error and status
// vocabulary, and the one operation that is pure ServiceManagement.

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

    /// Everything this app has done to the registration in this session, and what came back.
    /// Kept because "register() returned without throwing" is not evidence of anything — the
    /// transcript is what a bug report needs and what the log would otherwise have to carry.
    private(set) var transcript: [Entry] = []

    init() {
        note("launched: status = \(Self.describe(service.status))")
        note("bundle: \(Bundle.main.bundleURL.path)")
        note("BundleProgram target: \(Self.bundleProgramReport())")
    }

    // MARK: - Operations

    /// Record what a migration or repair actually did. The window shows a one-line verdict;
    /// this keeps the evidence behind it.
    func absorb(_ outcome: Migration.Outcome, label: String) {
        note("\(label): \(outcome.ok ? "reached a healthy state" : "DID NOT reach a healthy state")")
        outcome.lines.forEach { note("  " + $0) }
    }

    /// The only correct response to `.requiresApproval`. Measured in stage 2: `register()`
    /// throws "Operation not permitted" there and an unregister-then-register snaps straight
    /// back, so nothing the app can call will undo it. Taking the user to the switch is the
    /// whole remedy — and telling them to "go to System Settings" without taking them there is
    /// where this flow usually dies.
    func openLoginItems() {
        note("openSystemSettingsLoginItems()")
        SMAppService.openSystemSettingsLoginItems()
    }

    func copyTranscript() -> String {
        transcript.map { "\(Self.stamp.string(from: $0.at))  \($0.text)" }.joined(separator: "\n")
    }

    private func note(_ text: String) {
        transcript.append(Entry(text: text))
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Reporting

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
