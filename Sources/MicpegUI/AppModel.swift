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
        public var actionTitle: String?
        public var action: Action?

        public enum Action: Equatable { case openLoginItems, repairAgent, migrateLegacy }
    }

    // MARK: - Observable state

    public private(set) var agent: AgentCondition = .notKeeping
    public private(set) var daemon: DaemonState?
    public private(set) var config: PinnedConfig.ReadResult = .missing
    public private(set) var inputs: [AudioDevice] = []
    public private(set) var currentInput: AudioDevice?
    public private(set) var currentOutput: AudioDevice?
    public private(set) var activity: [Activity] = []

    /// Resolved once when the config is read. The alternative was turning a name into a
    /// four-character string per device per redraw to compare against another string built the
    /// same way — three allocations to answer a question about two integers.
    private var blockedCodes: Set<UInt32> = []

    private var fileWatch: DirectoryWatch?
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
    /// by all of them. Stopping on the first `onDisappear` released the HAL listeners and the
    /// directory watcher out from under every other window, and `startWatching`'s guard meant
    /// they never came back: the surviving window kept showing what it last read and silently
    /// stopped updating.
    private var watchers = 0

    /// Start watching. Separate from init so a preview can build a model without attaching
    /// HAL listeners or file descriptors.
    public func startWatching() {
        watchers += 1
        guard fileWatch == nil else { return }
        fileWatch = DirectoryWatch(directory: DaemonPaths.directory) { [weak self] in
            self?.reloadFiles()
        }
        deviceWatch = DeviceWatch { [weak self] in
            self?.reloadDevices()
        }
    }

    /// Releases the directory descriptor, its dispatch source and the three HAL listeners —
    /// once the last window has gone. Without it they stayed installed for the life of the
    /// process, watching for a window that was not there.
    public func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
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
        blockedCodes = AudioSnapshot.transportCodes(named: pinned?.blockedTransports ?? [])
        activity = Self.collapsed(ActivityLog.recent())
    }

    public func reloadDevices() {
        inputs = AudioSnapshot.inputDevices()
        // The default input is nearly always one of the devices just described, so look there
        // before asking the HAL for four more properties.
        let defaultInput = defaultInputDevice()
        currentInput = inputs.first { $0.id == defaultInput } ?? AudioSnapshot.currentInput()
        currentOutput = AudioSnapshot.currentOutput()
    }

    /// "Recent activity" answers one question — what happened to the user's microphone — and
    /// the daemon's log answers it more than once per event.
    ///
    /// A successful revert writes `REVERT -> X (…)` and then, immediately after, the
    /// transition it caused. Rendered straight through, the most important moment in the
    /// program produced two rows saying the same thing. The revert line is the one that names
    /// both devices, so the transition that follows it within a couple of seconds is dropped.
    /// Adjacent entries that would render as the same sentence collapse too: a run of daemon
    /// restarts otherwise repeats one line five times and buries the one that is news.
    ///
    /// Entries arrive newest first, so the transition is seen *before* the revert it belongs
    /// to.
    static func collapsed(_ entries: [Activity]) -> [Activity] {
        var out: [Activity] = []
        for (index, entry) in entries.enumerated() {
            let previous = index + 1 < entries.count ? entries[index + 1] : nil
            if entry.kind == .pinned || entry.kind == .resumed,
               let previous, case .restored = previous.kind,
               entry.at.timeIntervalSince(previous.at) < 2 {
                continue
            }
            if let last = out.last, last.kind == entry.kind { continue }
            out.append(entry)
        }
        return out
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
    public var targetName: String? {
        guard let first = pinned?.priority.first else { return nil }
        return first.name ?? first.uid
    }

    /// The chosen device, as a device rather than a name — nil when it is not connected.
    /// The picker opens on it so the user can see what is currently kept before changing it.
    public var pinnedDevice: AudioDevice? {
        guard let uid = pinned?.priority.first?.uid else { return nil }
        return inputs.first { $0.uid == uid }
    }

    public var targetIsConnected: Bool {
        guard let uid = pinned?.priority.first?.uid else { return false }
        return inputs.contains { $0.uid == uid }
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
            return targetIsConnected ? Copy.activeSummary(target) : Copy.waitingSummary(target)
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

        switch agent {
        case .needsApproval:
            return Banner(severity: .failure, title: Copy.approvalTitle,
                          body: Copy.approvalBody, actionTitle: Copy.approvalAction,
                          action: .openLoginItems)
        case .legacyPresent:
            return Banner(severity: .warning, title: Copy.legacyTitle,
                          body: Copy.legacyBody, actionTitle: Copy.legacyAction,
                          action: .migrateLegacy)
        case .notKeeping:
            guard hasSomethingToEnforce else { break }
            return Banner(severity: .failure, title: Copy.notRunningTitle,
                          body: Copy.notRunningBody, actionTitle: Copy.notRunningAction,
                          action: .repairAgent)
        case .otherCopyRunning(let path):
            return Banner(severity: .warning, title: Copy.otherCopyTitle,
                          body: Copy.otherCopyBody(path), actionTitle: nil, action: nil)
        case .repairedAfterMove(let from):
            return Banner(severity: .informational, title: Copy.movedTitle,
                          body: Copy.movedBody(from), actionTitle: nil, action: nil)
        case .healthy:
            break
        }

        if body == .settingsUnreadable {
            return Banner(severity: .warning, title: Copy.configUnreadableTitle,
                          body: Copy.configUnreadableBody, actionTitle: nil, action: nil)
        }
        if daemon?.kind == .backoff {
            return Banner(severity: .warning, title: Copy.conflictTitle,
                          body: Copy.conflictBody, actionTitle: nil, action: nil)
        }
        return nil
    }

    /// The silence hint, chosen by which device has gone quiet.
    public var silenceHint: String {
        currentInput?.isBuiltIn == true ? Copy.silenceHintBuiltIn : Copy.silenceHint
    }

    public func sentence(for activity: Activity) -> String {
        switch activity.kind {
        case .restored(let to, let displacing): return Copy.restored(to: to, displacing: displacing)
        case .steppedAside(let to):             return Copy.steppedAside(to: to)
        case .resumed:                          return Copy.resumedActivity
        case .pinned:                           return Copy.pinnedActivity(targetName ?? Copy.noDevice)
        case .targetMissing:                    return Copy.targetMissingActivity
        case .backedOff:                        return Copy.backedOffActivity
        case .problem(let problem):             return Copy.problem(problem)
        }
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
        let cli = self.cli
        let result = await Task.detached(priority: .userInitiated) { cli.pick(uid: uid) }.value
        reloadFiles()
        return result.ok ? nil : result.output
    }

    @discardableResult
    public func setPaused(_ paused: Bool) async -> String? {
        let cli = self.cli
        let result = await Task.detached(priority: .userInitiated) {
            cli.setEnabled(!paused)
        }.value
        reloadFiles()
        return result.ok ? nil : result.output
    }

    public func isBlocked(_ device: AudioDevice) -> Bool {
        blockedCodes.contains(device.transportCode)
    }

    // MARK: - Previews

    /// A model with fixed contents and no watchers, so a preview shows the same thing on
    /// every machine. The stored properties are `private(set)`, which is why this lives here
    /// rather than in an extension: previews must not be able to reach in from elsewhere.
    public static func preview(agent: AgentCondition = .healthy,
                               config: PinnedConfig.ReadResult = .ok(.init(
                                   enabled: true,
                                   priority: [.init(uid: "uid-wave", name: "Elgato Wave:1")],
                                   blockedTransports: ["bluetooth", "bluetoothle"]))) -> AppModel {
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
        model.blockedCodes = AudioSnapshot.transportCodes(named: ["bluetooth", "bluetoothle"])
        model.currentInput = model.inputs.first
        model.currentOutput = AudioDevice(id: 4, uid: "uid-out", name: "AirPods Pro",
                                          transportCode: kAudioDeviceTransportTypeBluetooth)
        return model
    }
}
