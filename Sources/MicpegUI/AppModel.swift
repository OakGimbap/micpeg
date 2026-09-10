// Everything the window renders, in one observable place.
//
// The model deliberately knows nothing about ServiceManagement. The window has to show
// whether the background agent is healthy, but *deciding* that is registration work — it needs
// SMAppService, the legacy plist, launchd and proc_pidpath, all of which live in the app
// target. So the app target reduces its verdict to `AgentCondition` and hands it in. Two
// benefits: this target stays free of ServiceManagement, and a preview can put the window into
// any of those conditions without a registration existing.
//
// Reads are cheap and are re-done from scratch on every change notification rather than
// patched incrementally. There are at most a dozen audio devices and two small JSON files; a
// diffing scheme here would be a source of staleness bugs in exchange for nothing.

import Foundation
import MicpegAudio

@MainActor
@Observable
public final class AppModel {

    /// The app target's verdict, reduced to what the window needs to say.
    public enum AgentCondition: Equatable, Sendable {
        /// Registered here and the daemon is running out of this bundle.
        case healthy
        /// Switched off in Login Items. Measured in stage 2: code cannot undo this.
        case needsApproval
        /// Nothing is registered. On a fresh install this is normal and onboarding handles it.
        case notRegistered
        /// A hand-written LaunchAgent from the old CLI install still holds the label.
        case legacyPresent
        /// A launchd job exists but nothing is running from it.
        case notRunning
        /// The app moved and re-registered itself. Worth saying once, not an error.
        case repairedAfterMove(from: String)
    }

    /// What the body of the window is showing. app-ui.md: "The skeleton is constant. Only the
    /// banner and the body change."
    public enum Body: Equatable {
        case unconfigured
        case configured
    }

    /// An exception worth interrupting for. `nil` is the healthy case, and the healthy case
    /// shows no banner at all.
    public struct Banner: Equatable {
        public enum Severity: Equatable { case informational, warning, failure }
        public var severity: Severity
        public var title: String
        public var body: String
        public var actionTitle: String?
        public var action: Action?

        public enum Action: Equatable { case openLoginItems, repairAgent, migrateLegacy }
    }

    // MARK: - Observable state

    public private(set) var agent: AgentCondition = .notRegistered
    public private(set) var daemon: DaemonState?
    public private(set) var config: PinnedConfig.ReadResult = .missing
    public private(set) var inputs: [AudioDevice] = []
    public private(set) var currentInput: AudioDevice?
    public private(set) var currentOutput: AudioDevice?
    public private(set) var activity: [Activity] = []

    private var fileWatch: DirectoryWatch?
    private var deviceWatch: DeviceWatch?
    private let cli: MicpegCLI

    public init(cli: MicpegCLI = .bundled, agent: AgentCondition = .notRegistered) {
        self.cli = cli
        self.agent = agent
        reloadAll()
    }

    /// Start watching. Separate from init so a preview can build a model without attaching
    /// HAL listeners or file descriptors.
    public func startWatching() {
        guard fileWatch == nil else { return }
        fileWatch = DirectoryWatch(directory: DaemonPaths.directory) { [weak self] in
            self?.reloadFiles()
        }
        deviceWatch = DeviceWatch { [weak self] in
            self?.reloadDevices()
        }
    }

    public func stopWatching() {
        fileWatch = nil
        deviceWatch = nil
    }

    public func setAgent(_ condition: AgentCondition) { agent = condition }

    // MARK: - Reloading

    public func reloadAll() {
        reloadFiles()
        reloadDevices()
    }

    public func reloadFiles() {
        daemon = DaemonState.read()
        config = PinnedConfig.read()
        activity = Self.collapsed(ActivityLog.recent())
    }

    /// "Recent activity" answers one question — what happened to the user's microphone — and
    /// two of the daemon's events are not answers to it.
    ///
    /// Every restart writes "starting" and then a pin a fraction of a second later, so a run
    /// of app updates rendered as *started / selected / started / selected / selected*.
    /// Measured on the real log, in the window. So `.started` is dropped outright, and the
    /// pins that follow it collapse into one: a microphone that has simply gone on working is
    /// not news, and repeating it five times makes the one line that *is* news harder to find.
    static func collapsed(_ entries: [Activity]) -> [Activity] {
        var out: [Activity] = []
        for entry in entries where entry.kind != .started {
            if let last = out.last, last.kind == entry.kind { continue }
            out.append(entry)
        }
        return out
    }

    public func reloadDevices() {
        inputs = AudioSnapshot.inputDevices()
        currentInput = AudioSnapshot.currentInput()
        currentOutput = AudioSnapshot.currentOutput()
    }

    // MARK: - Derived

    public var pinned: PinnedConfig? {
        if case .ok(let c) = config { return c }
        return nil
    }

    public var body: Body {
        guard let pinned, !pinned.isUnconfigured else { return .unconfigured }
        return .configured
    }

    /// The name of the device the user chose, from the config rather than from the daemon's
    /// state file: `state.json` reports `(absent)` for a target that is not connected, and the
    /// window still needs to name it in order to say "it isn't connected".
    public var targetName: String? {
        guard let first = pinned?.priority.first else { return nil }
        return first.name ?? first.uid
    }

    public var targetIsConnected: Bool {
        guard let uid = pinned?.priority.first?.uid else { return false }
        return inputs.contains { $0.uid == uid }
    }

    public var isPaused: Bool { pinned?.enabled == false }

    /// One sentence for the body, in the user's terms.
    public var summary: String {
        guard let target = targetName else { return Copy.unconfiguredSummary }
        if isPaused { return Copy.pausedSummary }
        switch daemon?.kind {
        case .yielded:
            return Copy.standingBySummary(daemon?.currentInput ?? Copy.noDevice, target: target)
        case .absent:
            return Copy.waitingSummary(target)
        case .pinned, .backoff, .paused, .none:
            return targetIsConnected ? Copy.activeSummary(target) : Copy.waitingSummary(target)
        }
    }

    /// Exceptions, most serious first. Only one is shown; the rest would be noise stacked on
    /// top of a problem the user has to solve before the others can matter.
    public var banner: Banner? {
        switch agent {
        case .needsApproval:
            return Banner(severity: .failure, title: Copy.approvalTitle,
                          body: Copy.approvalBody, actionTitle: Copy.approvalAction,
                          action: .openLoginItems)
        case .legacyPresent:
            return Banner(severity: .warning, title: Copy.legacyTitle,
                          body: Copy.legacyBody, actionTitle: Copy.legacyAction,
                          action: .migrateLegacy)
        case .notRunning:
            return Banner(severity: .failure, title: Copy.notRunningTitle,
                          body: Copy.notRunningBody, actionTitle: Copy.notRunningAction,
                          action: .repairAgent)
        case .repairedAfterMove(let from):
            return Banner(severity: .informational, title: Copy.movedTitle,
                          body: Copy.movedBody(from), actionTitle: nil, action: nil)
        case .notRegistered:
            // Before onboarding this is the expected state and says nothing worth interrupting
            // for. After a target exists it means the helper is gone.
            guard body == .configured else { return nil }
            return Banner(severity: .failure, title: Copy.notRunningTitle,
                          body: Copy.notRunningBody, actionTitle: Copy.notRunningAction,
                          action: .repairAgent)
        case .healthy:
            break
        }
        if case .unreadable = config {
            return Banner(severity: .warning, title: Copy.configUnreadableTitle,
                          body: Copy.configUnreadableBody, actionTitle: nil, action: nil)
        }
        if daemon?.kind == .backoff {
            return Banner(severity: .warning, title: Copy.conflictTitle,
                          body: Copy.conflictBody, actionTitle: nil, action: nil)
        }
        return nil
    }

    /// The silence hint, chosen by which device has gone quiet. `bltn` is the transport code
    /// CoreAudio reports for the built-in microphone, and the CLI prints the same tag.
    public var silenceHint: String {
        currentInput?.transport.trimmingCharacters(in: .whitespaces) == "bltn"
            ? Copy.silenceHintBuiltIn
            : Copy.silenceHint
    }

    public func sentence(for activity: Activity) -> String {
        switch activity.kind {
        case .restored(let to, let displacing): return Copy.restored(to: to, displacing: displacing)
        case .steppedAside(let to):             return Copy.steppedAside(to: to)
        case .resumed:                          return Copy.resumedActivity
        case .pinned:                           return Copy.pinnedActivity(targetName ?? Copy.noDevice)
        case .targetMissing:                    return Copy.targetMissingActivity
        case .backedOff:                        return Copy.backedOffActivity
        case .started:                          return Copy.startedActivity
        }
    }

    // MARK: - Mutations, all through the CLI

    /// Returns the CLI's message when it refuses, so the window can show it rather than
    /// silently doing nothing.
    @discardableResult
    public func pick(_ device: AudioDevice) -> String? {
        guard let uid = device.uid else { return "That device has no identifier to pin." }
        let result = cli.pick(uid: uid)
        reloadFiles()
        return result.ok ? nil : result.output
    }

    @discardableResult
    public func setPaused(_ paused: Bool) -> String? {
        let result = cli.setEnabled(!paused)
        reloadFiles()
        return result.ok ? nil : result.output
    }

    public func isBlocked(_ device: AudioDevice) -> Bool {
        AudioSnapshot.isBlocked(device, by: pinned?.blockedTransports ?? [])
    }

    // MARK: - Previews

    /// A model with fixed contents and no watchers, so a preview shows the same thing on
    /// every machine. The stored properties are `private(set)`, which is why this lives here
    /// rather than in an extension: previews must not be able to reach in from elsewhere.
    public static func preview(agent: AgentCondition = .healthy,
                               daemon: DaemonState? = nil,
                               config: PinnedConfig.ReadResult = .ok(.init(
                                   enabled: true,
                                   priority: [.init(uid: "uid-wave", name: "Elgato Wave:1")],
                                   blockedTransports: ["bluetooth", "bluetoothle"])),
                               inputs: [AudioDevice] = [
                                   AudioDevice(id: 1, uid: "uid-wave", name: "Elgato Wave:1",
                                               transport: "usb ", hasInput: true),
                                   AudioDevice(id: 2, uid: "uid-builtin",
                                               name: "MacBook Pro Microphone",
                                               transport: "bltn", hasInput: true),
                                   AudioDevice(id: 3, uid: "uid-pods", name: "AirPods Pro",
                                               transport: "blue", hasInput: true)],
                               activity: [Activity] = []) -> AppModel {
        let model = AppModel(cli: MicpegCLI(executable: URL(fileURLWithPath: "/usr/bin/false")),
                             agent: agent)
        model.daemon = daemon ?? DaemonState(kind: .pinned, reason: "dev#",
                                             target: "Elgato Wave:1",
                                             currentInput: "Elgato Wave:1",
                                             updated: Date(), rawKind: "PINNED")
        model.config = config
        model.inputs = inputs
        model.currentInput = inputs.first
        model.currentOutput = AudioDevice(id: 4, uid: "uid-out", name: "AirPods Pro",
                                          transport: "blue", hasInput: false)
        model.activity = activity
        return model
    }
}
