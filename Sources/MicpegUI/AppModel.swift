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
// patched incrementally. There are at most a dozen audio devices, two small JSON files and a
// log capped at 256 KB; a diffing scheme here would be a source of staleness bugs in exchange
// for nothing.

import Foundation
import CoreAudio
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
        /// A hand-written LaunchAgent from the old CLI install still holds the label.
        case legacyPresent
        /// Nothing is keeping the microphone: not registered, or registered and unspawnable.
        /// One condition because it is one sentence to the user and one repair.
        case notKeeping
        /// A *different* copy of Micpeg registered the agent and its daemon is running.
        ///
        /// Deliberately not folded into `notKeeping`. The helper is running, so
        /// "The background helper isn't running" would be false, and the Reconnect button
        /// would take the registration off the copy that currently has it — a fight the user
        /// did not ask for, between two copies of the same app.
        case otherCopyRunning(at: String)
        /// The app moved and re-registered itself. Worth saying once, not an error.
        case repairedAfterMove(from: String)
    }

    /// What the body of the window is showing. app-ui.md: "The skeleton is constant. Only the
    /// banner and the body change."
    public enum Body: Equatable {
        case unconfigured
        case configured
        /// There is a settings file and it does not parse. Deliberately not `unconfigured`:
        /// the daemon is still running on the settings it loaded last, so offering to set
        /// things up from scratch would be a lie about what is happening.
        case settingsUnreadable
    }

    /// An exception worth interrupting for. `nil` is the healthy case, and the healthy case
    /// shows no banner at all.
    public struct Banner: Equatable {
        public enum Severity: Equatable { case informational, warning, failure }
        public var severity: Severity
        public var title: String
        public var body: String
        public var action: Action? = nil

        public enum Action: Equatable {
            case openLoginItems, repairAgent, migrateLegacy
            /// Opens the Activity window. Handled by the window itself, which has the
            /// environment to open another; the rest are registration work for the app target.
            case showActivity

            /// Each action has one button title, so the title belongs to the action rather
            /// than to a second optional every banner had to remember to set alongside it.
            public var title: String {
                switch self {
                case .openLoginItems: return Copy.approvalAction
                case .repairAgent:    return Copy.notRunningAction
                case .migrateLegacy:  return Copy.legacyAction
                case .showActivity:   return Copy.showActivity
                }
            }
        }
    }

    // MARK: - Observable state

    public private(set) var agent: AgentCondition = .notKeeping
    public private(set) var daemon: DaemonState?
    public private(set) var config: PinnedConfig.ReadResult = .missing
    public private(set) var inputs: [AudioDevice] = []
    public private(set) var currentInput: AudioDevice?
    public private(set) var currentOutput: AudioDevice?
    /// Newest first. Shown in the Activity window; read here too, because a failed revert
    /// appears nowhere else and the main window's banner has to be able to say so.
    public private(set) var activity: [Activity] = []

    private var fileWatch: PathWatch?
    private var logWatch: PathWatch?
    private var deviceWatch: DeviceWatch?
    private let cli: MicpegCLI

    /// Does no I/O. The window's `.task` loads everything once it is on screen, and the
    /// watchers fire on attach — three separate full reloads happened before the first frame
    /// until this was left empty.
    public init(cli: MicpegCLI = .bundled) {
        self.cli = cli
    }

    /// How many windows are currently relying on the watchers.
    ///
    /// `WindowGroup` gives File ▸ New Window for free, and this model is one `@State` shared
    /// by all of them — and by the Activity window. Stopping on the first `onDisappear`
    /// released the HAL listeners and the watchers out from under every other window, and
    /// `startWatching`'s guard meant they never came back: the surviving window kept showing
    /// what it last read and silently stopped updating.
    private var watchers = 0

    /// Start watching. Separate from init so a preview can build a model without attaching
    /// HAL listeners or file descriptors.
    public func startWatching() {
        watchers += 1
        guard fileWatch == nil else { return }
        fileWatch = PathWatch(DaemonPaths.directory, kind: .directory) { [weak self] in
            self?.reloadState()
        }
        // Its own watch: a failed revert writes a log line and nothing else — no state.json —
        // and the failure banner has to notice it. FileWatch.swift says why this one watches
        // the file and the other the directory.
        logWatch = PathWatch(DaemonPaths.log, kind: .appendedFile) { [weak self] in
            self?.reloadActivity()
        }
        deviceWatch = DeviceWatch { [weak self] in
            self?.reloadDevices()
        }
    }

    /// Releases both watched descriptors, their dispatch sources and the three HAL listeners —
    /// once the last window has gone. Without it they stayed installed for the life of the
    /// process, watching for a window that was not there.
    public func stopWatching() {
        // Every scene pairs this with its own startWatching() through onAppear/onDisappear,
        // which SwiftUI matches. An unmatched stop would take the watchers out from under a
        // window still relying on them, so it is a bug to find rather than a count to clamp.
        assert(watchers > 0, "stopWatching() without a matching startWatching()")
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        fileWatch = nil
        logWatch = nil
        deviceWatch = nil
    }

    public func setAgent(_ condition: AgentCondition) { agent = condition }

    // MARK: - Reloading

    public func reloadAll() {
        reloadState()
        reloadActivity()
        reloadDevices()
    }

    /// `state.json` and `config.json` — on the directory watch, and after every CLI call.
    public func reloadState() {
        daemon = DaemonState.read()
        config = PinnedConfig.read()
    }

    /// The log, on its own watch. A transition writes both the log and `state.json`; keeping
    /// the reloads apart means neither write re-reads the other's file.
    public func reloadActivity() {
        activity = ActivityLog.recent()
    }

    public func reloadDevices() {
        inputs = AudioSnapshot.inputDevices()
        // The default input is nearly always one of the devices just described, so look there
        // before asking the HAL for four more properties.
        let defaultInput = defaultInputDevice()
        currentInput = inputs.first { $0.id == defaultInput } ?? AudioSnapshot.currentInput()
        currentOutput = AudioSnapshot.currentOutput()
    }

    // MARK: - Derived

    public var pinned: PinnedConfig? {
        if case .ok(let c) = config { return c }
        return nil
    }

    public var body: Body {
        switch config {
        case .missing:              return .unconfigured
        case .unreadable:           return .settingsUnreadable
        case .ok(let c):            return c.isUnconfigured ? .unconfigured : .configured
        }
    }

    /// The name of the device the user chose, from the config rather than from the daemon's
    /// state file: `state.json` reports `(absent)` for a target that is not connected, and the
    /// window still needs to name it in order to say "it isn't connected".
    public var targetName: String? { pinned?.targetName }

    /// The chosen device, as a device rather than a name — nil when it is not connected.
    /// The picker opens on it so the user can see what is currently kept before changing it.
    public var pinnedDevice: AudioDevice? {
        guard let uid = pinned?.priority.first?.uid else { return nil }
        return inputs.first { $0.uid == uid }
    }

    public var targetIsConnected: Bool { pinnedDevice != nil }

    /// The microphone the daemon would keep right now: the first priority entry that is
    /// connected, by UID and otherwise by name — the daemon's own rule (`resolveTarget()` in
    /// main.swift). `pinnedDevice` looks only at the first entry, which is right for the picker
    /// and not for "is the input what Micpeg would choose".
    public var keptDevice: AudioDevice? {
        for entry in pinned?.priority ?? [] {
            if let uid = entry.uid, let device = inputs.first(where: { $0.uid == uid }) {
                return device
            }
            if let name = entry.name, let device = inputs.first(where: { $0.name == name }) {
                return device
            }
        }
        return nil
    }

    /// Whether the input in use is the one Micpeg keeps. The ✓ and the summary used to claim
    /// it from the daemon's state alone, and a failed revert leaves that state at PINNED
    /// (`revert(to:reason:)` returns before its transition) — so both said "stays your
    /// microphone" beside an Input row that named another one.
    public var inputIsTarget: Bool {
        guard let kept = keptDevice, let current = currentInput else { return false }
        return kept.id == current.id
    }

    public var isPaused: Bool { pinned?.enabled == false }

    /// One sentence for the body, in the user's terms.
    public var summary: String {
        if body == .settingsUnreadable { return Copy.settingsUnreadableSummary }
        guard let target = targetName else { return Copy.unconfiguredSummary }
        if isPaused { return Copy.pausedSummary }
        switch daemon?.kind {
        case .yielded:
            return Copy.standingBySummary(daemon?.currentInput ?? Copy.noDevice, target: target)
        case .absent:
            return Copy.waitingSummary(target)
        case .pinned, .backoff, .paused, .unknown, .none:
            guard targetIsConnected else { return Copy.waitingSummary(target) }
            return inputIsTarget ? Copy.activeSummary(target) : Copy.notInUseSummary(target)
        }
    }

    /// Exceptions, most serious first. Only one is shown; the rest would be noise stacked on
    /// top of a problem the user has to solve before the others can matter.
    public var banner: Banner? {
        // A banner about the microphone not being kept is nonsense before a microphone has
        // been chosen. This is one rule applied once rather than a guard bolted onto whichever
        // condition happened to be noticed first — the earlier version guarded only the
        // not-registered case, so a new user opening the app on a machine with a stale launchd
        // job was told their microphone was not being kept when they had not picked one.
        let hasSomethingToEnforce = body == .configured

        // First, nothing is running to keep the microphone at all.
        switch agent {
        case .needsApproval:
            return Banner(severity: .failure, title: Copy.approvalTitle,
                          body: Copy.approvalBody, action: .openLoginItems)
        case .legacyPresent:
            return Banner(severity: .warning, title: Copy.legacyTitle,
                          body: Copy.legacyBody, action: .migrateLegacy)
        case .notKeeping:
            if hasSomethingToEnforce {
                return Banner(severity: .failure, title: Copy.notRunningTitle,
                              body: Copy.notRunningBody, action: .repairAgent)
            }
        case .otherCopyRunning, .repairedAfterMove, .healthy:
            break
        }

        // Then the microphone being wrong right now, which outranks everything below: those
        // describe how Micpeg is set up, and this is the job itself not getting done.
        if let restoreFailed = restoreFailedBanner { return restoreFailed }

        switch agent {
        case .otherCopyRunning(let path):
            return Banner(severity: .warning, title: Copy.otherCopyTitle,
                          body: Copy.otherCopyBody(path))
        case .repairedAfterMove(let from):
            return Banner(severity: .informational, title: Copy.movedTitle,
                          body: Copy.movedBody(from))
        case .needsApproval, .legacyPresent, .notKeeping, .healthy:
            break
        }

        if body == .settingsUnreadable {
            return Banner(severity: .warning, title: Copy.configUnreadableTitle,
                          body: Copy.configUnreadableBody)
        }
        if daemon?.kind == .backoff {
            return Banner(severity: .warning, title: Copy.conflictTitle,
                          body: Copy.conflictBody)
        }
        return nil
    }

    /// The one failure only the log can report: a revert that did not take. It moved out of
    /// the main window with the activity list, and this is what keeps it from moving out of
    /// sight. All three conditions must hold, and each is there because of a way it could lie:
    ///
    ///   - Micpeg is meant to be keeping the microphone: configured, not paused, and not
    ///     standing aside, paused or backed off. A failed revert leaves the state wherever it
    ///     was (`revert(to:reason:)` returns before its transition), so the state alone cannot
    ///     say it failed.
    ///   - The newest event about the input is the failure. Without this, the few hundred
    ///     milliseconds between macOS switching and Micpeg switching back would flash it.
    ///   - Right now, live, the kept microphone is connected and is not the input. Fixing it by
    ///     hand in System Settings leaves the state at PINNED, so `transition()` writes no
    ///     line, and the `JUDGED` diagnostic `evaluate()` writes instead is not an event. A rule
    ///     read from the log alone would stay up forever.
    private var restoreFailedBanner: Banner? {
        guard body == .configured, !isPaused else { return nil }
        switch daemon?.kind {
        case .yielded, .paused, .backoff: return nil
        case .pinned, .absent, .unknown, .none: break
        }
        guard activity.first(where: \.kind.concernsTheInput)?.kind == .problem(.restoreFailed),
              let kept = keptDevice, !inputIsTarget else { return nil }
        return Banner(severity: .warning, title: Copy.restoreFailedTitle,
                      body: Copy.restoreFailedBody(kept.name), action: .showActivity)
    }

    /// The silence hint, chosen by which device has gone quiet.
    public var silenceHint: String {
        currentInput?.isBuiltIn == true ? Copy.silenceHintBuiltIn : Copy.silenceHint
    }

    // MARK: - Mutations, all through the CLI

    /// Returns the CLI's message when it refuses, so the window can show it rather than
    /// silently doing nothing.
    ///
    /// `async` because the CLI call is a fork, an exec, a CoreAudio enumeration, a file write
    /// and a signal. Run inline it froze the window — including the 30 Hz meter — for the
    /// whole of that.
    @discardableResult
    public func pick(_ device: AudioDevice) async -> String? {
        guard let uid = device.uid else { return Copy.deviceHasNoIdentifier }
        return await mutate { $0.pick(uid: uid) }
    }

    @discardableResult
    public func setPaused(_ paused: Bool) async -> String? {
        await mutate { $0.setEnabled(!paused) }
    }

    /// The CLI call off the main actor, then a fresh read of what it changed.
    private func mutate(_ call: @escaping @Sendable (MicpegCLI) -> MicpegCLI.Result) async
        -> String? {
        let cli = self.cli
        let result = await Task.detached(priority: .userInitiated) { call(cli) }.value
        reloadState()
        return result.ok ? nil : result.output
    }

    public func isBlocked(_ device: AudioDevice) -> Bool {
        pinned?.blockedTransportCodes.contains(device.transportCode) ?? false
    }

    // MARK: - Previews

    /// A model with fixed contents and no watchers, so a preview shows the same thing on
    /// every machine. The stored properties are `private(set)`, which is why this lives here
    /// rather than in an extension: previews must not be able to reach in from elsewhere.
    public static func preview(agent: AgentCondition = .healthy,
                               config: PinnedConfig.ReadResult = .ok(.init(
                                   enabled: true,
                                   priority: [.init(uid: "uid-wave", name: "Elgato Wave:1")],
                                   blockedTransports: ["bluetooth", "bluetoothle"])),
                               currentInputUID: String = "uid-wave",
                               activity: [Activity] = []) -> AppModel {
        let model = AppModel(cli: MicpegCLI(executable: URL(fileURLWithPath: "/usr/bin/false")))
        model.agent = agent
        model.config = config
        model.daemon = DaemonState(kind: .pinned, currentInput: "Elgato Wave:1")
        model.inputs = [
            AudioDevice(id: 1, uid: "uid-wave", name: "Elgato Wave:1",
                        transportCode: kAudioDeviceTransportTypeUSB),
            AudioDevice(id: 2, uid: "uid-builtin", name: "MacBook Pro Microphone",
                        transportCode: kAudioDeviceTransportTypeBuiltIn),
            AudioDevice(id: 3, uid: "uid-pods", name: "AirPods Pro",
                        transportCode: kAudioDeviceTransportTypeBluetooth)]
        model.currentInput = model.inputs.first { $0.uid == currentInputUID }
        model.currentOutput = AudioDevice(id: 4, uid: "uid-out", name: "AirPods Pro",
                                          transportCode: kAudioDeviceTransportTypeBluetooth)
        model.activity = activity
        return model
    }

    /// One of every kind of row a real log produces, newest first, spread over two days.
    public static var previewActivity: [Activity] {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let wave = Activity.Device(name: "Elgato Wave:1", transport: kAudioDeviceTransportTypeUSB)
        let pods = Activity.Device(name: "AirPods Pro",
                                   transport: kAudioDeviceTransportTypeBluetooth)
        let builtIn = Activity.Device(name: "MacBook Pro Microphone",
                                      transport: kAudioDeviceTransportTypeBuiltIn)
        return [
            Activity(at: ago(20), kind: .restored(to: wave, from: pods), raw: "a"),
            Activity(at: ago(12 * 60), kind: .chose(to: wave, from: builtIn), raw: "b"),
            Activity(at: ago(13 * 60), kind: .switchedAway(to: builtIn), raw: "c"),
            Activity(at: ago(50 * 60), kind: .resumed(to: nil, from: nil), raw: "d"),
            Activity(at: ago(52 * 60), kind: .paused, raw: "e"),
            Activity(at: ago(3 * 3600), kind: .reconnected, raw: "f"),
            Activity(at: ago(3 * 3600 + 400), kind: .disconnected, raw: "g"),
            Activity(at: ago(26 * 3600), kind: .problem(.restoreFailed), raw: "h"),
            Activity(at: ago(27 * 3600), kind: .started, raw: "i", count: 3),
        ]
    }
}

private extension Activity.Kind {
    /// Everything that says which microphone is in use, or that setting it failed — as opposed
    /// to the problems about Micpeg's own files and listeners, and the conflict, which has a
    /// banner of its own.
    var concernsTheInput: Bool {
        switch self {
        case .problem(.audioSystemLost), .problem(.statusNotSaved),
             .problem(.settingsUnreadable), .backedOff:
            return false
        default:
            return true
        }
    }
}
