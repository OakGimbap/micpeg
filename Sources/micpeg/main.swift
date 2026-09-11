// micpeg — pins the macOS default audio INPUT device.
//
// Scope discipline: this program reads and writes exactly one system property,
// kAudioHardwarePropertyDefaultInputDevice. It never touches the default output,
// the default system output, volume, mute, or per-app device selection.

import CoreAudio
import Darwin
import Foundation
import MicpegAudio

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let configPath = home.appendingPathComponent(".config/micpeg/config.json")
let statePath  = home.appendingPathComponent(".config/micpeg/state.json")
let logPath    = home.appendingPathComponent("Library/Logs/micpeg.log")
let plistPath  = home.appendingPathComponent("Library/LaunchAgents/com.micpeg.agent.plist")
let binPath    = home.appendingPathComponent(".local/bin/micpeg")
let agentLabel = "com.micpeg.agent"

// MARK: - Logging

/// `en_US_POSIX`, because a fixed format string is otherwise read in the user's locale and
/// calendar. Measured: with the region set to Thailand this wrote the Buddhist year 2569, with a
/// Japanese calendar 0008, and with an Islamic one Arabic-Indic digits — and the app parses these
/// stamps (ActivityLog, and `updated` in state.json) with a POSIX parser that accepted all three
/// as Gregorian years instead of rejecting them, so every row on a Thai-region Mac read
/// "Just now".
private let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    fputs("\(stampFormatter.string(from: Date())) \(message)\n", stderr)
}

// The daemon writes its log to stderr and nowhere else, so the file at ~/Library/Logs
// exists only because something redirects fd 2 there. The hand-written LaunchAgent did it
// with StandardErrorPath. The agent plist that ships inside Micpeg.app cannot: launchd does
// not expand `~`, and a plist built before the user exists cannot spell out their home
// directory — and a tilde there is not merely ignored, it makes launchd refuse the whole job
// with EX_CONFIG. So an SMAppService-registered agent starts with fd 2 on /dev/null and
// every line above is discarded; 324 bytes of startup log went missing that way before it
// was noticed. See docs/verification.md.
//
// Redirect only in that exact case. `micpeg daemon` run by hand in a shell has to keep
// printing to that shell — that is how the CoreAudio traps in design.md were found — and a
// `2>somewhere` the user typed must be left alone. So the test is not isatty(), which would
// also catch a pipe and a redirect to a file: it is "is fd 2 literally /dev/null", which is
// what launchd hands a job whose plist names no StandardErrorPath.
func redirectStderrToLogIfDiscarded() {
    var current = stat()
    var devNull = stat()
    guard fstat(2, &current) == 0,
          (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFCHR),
          stat("/dev/null", &devNull) == 0,
          current.st_rdev == devNull.st_rdev else { return }

    try? FileManager.default.createDirectory(at: logPath.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    // O_APPEND so this descriptor keeps writing at the end even after
    // truncateLogIfLarge() has cut the file out from under it.
    let fd = open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    if fd != 2 { dup2(fd, 2); close(fd) }
    log("stderr was /dev/null — logging to \(logPath.path)")
}

// MARK: - CoreAudio

// The read-only helpers (addr, allDevices, deviceUID, hasInput, transportType, …) live
// in the MicpegAudio module now, shared with the app. What stays here is the project's
// only CoreAudio write. It stays in the daemon target on purpose: docs/app-design.md
// turns "the app writes nothing to CoreAudio" into a CI grep, and that grep only means
// something while this function has exactly one home.

@discardableResult
func setDefaultInputDevice(_ id: AudioDeviceID) -> OSStatus {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice)
    var v = id
    return AudioObjectSetPropertyData(systemObject, &a, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &v)
}

// MARK: - Config

struct DeviceRef: Codable {
    var uid: String?
    var name: String?
}

struct InputConfig: Codable {
    var priority: [DeviceRef]
}

/// Distinguishes "no config yet" from "config we cannot understand". Collapsing the
/// two is how a corrupt file used to be silently rewritten as an empty target list.
enum ConfigLoad {
    case missing
    case ok(Config)
    case corrupt(String)
}

private func clampInt(_ v: Int, _ lo: Int, _ hi: Int, _ label: String) -> Int {
    if v < lo || v > hi {
        let c = min(max(v, lo), hi)
        log("config: \(label)=\(v) outside \(lo)...\(hi); using \(c)")
        return c
    }
    return v
}

private func clampDouble(_ v: Double, _ lo: Double, _ hi: Double,
                         _ fallback: Double, _ label: String) -> Double {
    guard v.isFinite else {
        log("config: \(label) is not a finite number; using \(fallback)")
        return fallback
    }
    if v < lo || v > hi {
        let c = min(max(v, lo), hi)
        log("config: \(label)=\(v) outside \(lo)...\(hi); using \(c)")
        return c
    }
    return v
}

struct Config: Codable {
    var enabled: Bool
    var input: InputConfig
    var blockTransports: [String]
    var arrivalWindowSeconds: Double
    var debounceMs: Int
    var reverifyDelaySeconds: Double
    var postWriteGraceSeconds: Double

    static let fallback = Config(
        enabled: true,
        input: InputConfig(priority: []),
        blockTransports: ["bluetooth", "bluetoothle"],
        arrivalWindowSeconds: 15,
        debounceMs: 300,
        reverifyDelaySeconds: 1.0,
        postWriteGraceSeconds: 3.0)

    init(enabled: Bool, input: InputConfig, blockTransports: [String],
         arrivalWindowSeconds: Double, debounceMs: Int, reverifyDelaySeconds: Double,
         postWriteGraceSeconds: Double) {
        self.enabled = enabled
        self.input = input
        self.blockTransports = blockTransports
        self.arrivalWindowSeconds = arrivalWindowSeconds
        self.debounceMs = debounceMs
        self.reverifyDelaySeconds = reverifyDelaySeconds
        self.postWriteGraceSeconds = postWriteGraceSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.fallback
        // A key that is PRESENT must decode; only an absent key takes a default.
        // Substituting a default for a malformed value is how a half-edited file
        // turns into an empty priority list that then gets written back.
        enabled = c.contains(.enabled)
            ? try c.decode(Bool.self, forKey: .enabled) : d.enabled
        input = c.contains(.input)
            ? try c.decode(InputConfig.self, forKey: .input) : d.input
        blockTransports = c.contains(.blockTransports)
            ? try c.decode([String].self, forKey: .blockTransports) : d.blockTransports
        arrivalWindowSeconds = c.contains(.arrivalWindowSeconds)
            ? try c.decode(Double.self, forKey: .arrivalWindowSeconds) : d.arrivalWindowSeconds
        debounceMs = c.contains(.debounceMs)
            ? try c.decode(Int.self, forKey: .debounceMs) : d.debounceMs
        reverifyDelaySeconds = c.contains(.reverifyDelaySeconds)
            ? try c.decode(Double.self, forKey: .reverifyDelaySeconds) : d.reverifyDelaySeconds
        postWriteGraceSeconds = c.contains(.postWriteGraceSeconds)
            ? try c.decode(Double.self, forKey: .postWriteGraceSeconds) : d.postWriteGraceSeconds
    }

    /// Degenerate timings silently disable the mechanisms the judgment depends on:
    /// debounceMs 0 removes the coalescing that lets one evaluate() see a settled
    /// device, and postWriteGraceSeconds 0 removes flip-back detection entirely.
    func validated() -> Config {
        var c = self
        let d = Config.fallback
        c.arrivalWindowSeconds = clampDouble(c.arrivalWindowSeconds, 1, 120,
                                             d.arrivalWindowSeconds, "arrivalWindowSeconds")
        c.debounceMs = clampInt(c.debounceMs, 50, 5000, "debounceMs")
        c.reverifyDelaySeconds = clampDouble(c.reverifyDelaySeconds, 0.1, 10,
                                             d.reverifyDelaySeconds, "reverifyDelaySeconds")
        c.postWriteGraceSeconds = clampDouble(c.postWriteGraceSeconds, 0.5, 30,
                                              d.postWriteGraceSeconds, "postWriteGraceSeconds")
        return c
    }

    static func read() -> ConfigLoad {
        guard FileManager.default.fileExists(atPath: configPath.path) else { return .missing }
        guard let data = try? Data(contentsOf: configPath) else {
            return .corrupt("cannot read \(configPath.path)")
        }
        do {
            return .ok(try JSONDecoder().decode(Config.self, from: data).validated())
        } catch {
            return .corrupt("\(error)")
        }
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: configPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Atomic: a crash or full disk mid-write must not leave truncated JSON that
        // the next load would reject.
        try enc.encode(self).write(to: configPath, options: .atomic)
    }

    func blockedTransports() -> Set<UInt32> {
        Set(blockTransports.compactMap { transportCode($0) })
    }

    /// An unresolvable blocklist turns the daemon into a no-op, so say so out loud.
    func reportBlocklistProblems(_ emit: (String) -> Void) {
        let unknown = blockTransports.filter { transportCode($0) == nil }
        if !unknown.isEmpty {
            emit("WARNING: unrecognized blockTransports ignored: \(unknown.joined(separator: ", "))"
               + " — valid names: \(transportNames.joined(separator: ", "))")
        }
        if blockedTransports().isEmpty {
            emit("WARNING: blockTransports resolves to nothing, so no transport counts as "
               + "an automatic switch and the pin will never be enforced.")
        }
    }
}

// MARK: - State

enum State: String, Codable {
    case absent  = "ABSENT"
    case pinned  = "PINNED"
    case yielded = "YIELDED"
    case paused  = "PAUSED"
    case backoff = "BACKOFF"
}

struct StateFile: Codable {
    var state: String
    var reason: String
    var target: String
    var currentInput: String
    var updated: String
}

// MARK: - Daemon

final class Daemon {
    /// All state lives on `work`. HAL notifications are delivered on `hal` and hop
    /// to `work` immediately, so tearing listeners down (which happens on `work`)
    /// never has to wait on the queue those listeners are being dispatched to.
    let work = DispatchQueue(label: "com.micpeg.work")
    let hal  = DispatchQueue(label: "com.micpeg.hal")

    var config = Config.fallback
    var configMTime: Date?
    var configEverLoaded = false

    var state: State = .absent
    var knownUIDs: Set<String> = []
    var arrivals: [String: Date] = [:]
    /// Last time any blocked-transport device appeared. AirPods publish their input
    /// and output objects at different moments and the input object does not reliably
    /// look "new" on a reconnect, so the narrower per-UID window alone misses the grab.
    var lastBlockedArrival: Date?
    /// While set, treat any default-input move as the system re-deciding rather than
    /// the user choosing. Armed on start and on a HAL reset — in both cases there is
    /// no history to judge against and macOS is (re)establishing every default.
    var systemChurnUntil: Date?
    /// UID the current yield was granted to. A yield must expire when that device
    /// leaves, otherwise it persists forever and the pin silently never comes back.
    var yieldedTo: String?
    /// When we last successfully wrote the default input. A change that lands within
    /// a moment of our own write is a flip-back, not a person choosing a device.
    var lastWriteAt: Date?

    /// Device we just wrote, plus when. Timestamped so a notification that never
    /// arrives cannot leave a stale expectation that swallows a real user change.
    var expectedSelfWrite: (device: AudioDeviceID, at: Date)?

    var revertTimes: [Date] = []
    var backoffUntil: Date?
    var backoffWakeArmed = false

    /// Bounded, so a device that never publishes an input scope cannot turn into a
    /// permanent 1 Hz poll — the whole design rests on zero idle wakeups.
    var inputScopeRetries = 0
    var inputScopeRetryArmed = false
    static let maxInputScopeRetries = 5

    var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var debounceItem: DispatchWorkItem?
    var stateWriteFailed = false
    /// Which known UIDs have an input scope. Needed because a device that has already
    /// left cannot be queried, and we must still know whether its departure mattered.
    var inputCapableUIDs: Set<String> = []
    /// Last reason actually persisted, so an unchanged state stops rewriting the file.
    var lastWrittenReason: String?
    /// When the current debounce window opened, so a stream of notifications arriving
    /// faster than the interval cannot postpone the judgment forever.
    var debounceFirstAt: Date?
    /// One-shot re-judgement guard. Bounded and self-disarming: no steady-state timer.
    var reconcileArmed = false
    /// One-shot guard for the retry after a write CoreAudio refused. See `retryRevertOnce()`.
    var revertRetryArmed = false
    /// One-shot guard for applyPin()'s retry after an unreadable default input. See
    /// `handleUnreadableDefault(_:pinning:)`.
    var pinRetryArmed = false

    // MARK: Listener plumbing

    func addListener(_ selector: AudioObjectPropertySelector,
                     _ handler: @escaping () -> Void) {
        var a = addr(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.work.async { handler() }
        }
        let st = AudioObjectAddPropertyListenerBlock(systemObject, &a, hal, block)
        guard st == noErr else {
            // Continuing here would leave the daemon running and permanently deaf to
            // this property — indistinguishable from working. launchd has KeepAlive,
            // so exiting is the only option that can actually recover.
            log("FATAL: could not add listener \(fourCC(selector)) status=\(osStatusText(st));"
              + " exiting so launchd relaunches")
            exit(1)
        }
        listeners.append((a, block))
    }

    func removeAllListeners() {
        for entry in listeners {
            var a = entry.0
            AudioObjectRemovePropertyListenerBlock(systemObject, &a, hal, entry.1)
        }
        listeners.removeAll()
    }

    func registerAll() {
        addListener(kAudioHardwarePropertyDevices)            { [weak self] in self?.onDeviceList() }
        addListener(kAudioHardwarePropertyDefaultInputDevice)  { [weak self] in self?.onDefaultInput() }
        addListener(kAudioHardwarePropertyServiceRestarted)    { [weak self] in self?.onServiceRestarted() }
        log("listeners registered: dev# dIn  srst")
    }

    // MARK: Events

    /// coreaudiod restarts during ordinary use — measured on this machine at once in
    /// 16 days of uptime. Every listener dies with it, silently. This is the only
    /// notification that says so.
    func onServiceRestarted() {
        log("EVENT srst — coreaudiod restarted; re-registering listeners")
        removeAllListeners()
        registerAll()
        // A pending self-write expectation is meaningless after a reset.
        expectedSelfWrite = nil

        // Deliberately NOT cleared: arrivals, lastBlockedArrival, knownUIDs, yieldedTo.
        // Arrival timestamps survive a HAL reset perfectly well, and wiping them is
        // exactly how this path failed twice: this runs after the 'dev#' handler has
        // recorded the arrivals, so clearing them destroyed the only evidence the
        // 'dIn ' event seconds later had to work from, and the daemon yielded to the
        // AirPods. snapshotDevices() is absent for the same reason — under the
        // opposite ordering it would suppress arrivals before 'dev#' ever saw them.
        armSystemChurn("HAL reset")
        applyPin(reason: "srst recovery")
    }

    /// Records arrivals and re-applies the pin. Deliberately does NOT make the
    /// yield judgment — that belongs to the default-input listener alone.
    func onDeviceList() {
        let current = Set(allDevices().compactMap { deviceUID($0) })
        let added = current.subtracting(knownUIDs)
        let removed = knownUIDs.subtracting(current)
        knownUIDs = current
        guard !added.isEmpty || !removed.isEmpty else { return }

        // An output-only device appearing or leaving cannot change which INPUT is the
        // default, so none of the work below is warranted for one. Measured over 24h:
        // an LG UltraFine re-published its audio endpoint every 11.3s for eight hours
        // straight — 3243 events, 94% of the log, 32.6s of CPU and 3.6MB of heap
        // high-water, entirely for a device with no input scope at all.
        // Input scope is queried only for what actually arrived; for departures the
        // remembered set answers it, since the device is already gone.
        let targets = Set(targetUIDs())
        let blocked = config.blockedTransports()
        var addedInputs: Set<String> = []
        var addedBlocked = false
        for uid in added {
            guard let id = deviceID(forUID: uid) else { continue }
            if hasInput(id) { addedInputs.insert(uid) }
            // A blocked-transport arrival counts even when it is output-only. Measured:
            // the AirPods publish their output object ~16ms before their input object,
            // and macOS had already moved the default input by the time the output
            // object appeared — that event is the earliest evidence of the grab, and on
            // one reconnect it was the *only* object that registered as new.
            if blocked.contains(transportType(id)) { addedBlocked = true }
        }
        let relevant = !addedInputs.isEmpty || addedBlocked
            || added.contains { targets.contains($0) }
            || removed.contains { inputCapableUIDs.contains($0) || targets.contains($0) }

        // Keep the capability memory current whether or not we act on this event.
        inputCapableUIDs.formUnion(addedInputs)
        inputCapableUIDs.subtract(removed)

        guard relevant else { return }

        // A rebuild is when nothing survived: wake, HAL reset or fast user switching
        // re-enumerates the whole list so every device looks new.
        let isRebuild = !added.isEmpty && added.count == current.count
        if isRebuild { log("EVENT dev# — full list rebuild (\(added.count) devices)") }

        // Arrivals are ALWAYS recorded, rebuild or not. Measured the hard way:
        // suppressing them on a rebuild left the 'dIn ' path with no evidence when
        // macOS moved the default input 4.8s after a coreaudiod restart, so it yielded
        // and the mic stayed on the AirPods. A wake rebuilds the list every day.
        let now = Date()
        for uid in added {
            arrivals[uid] = now
            // Name the transport on arrival: the only place the blocklist can be
            // checked against reality without waiting for a misfire.
            if let id = deviceID(forUID: uid) {
                let blocked = config.blockedTransports().contains(transportType(id))
                if blocked { lastBlockedArrival = now }
                log("ARRIVED \(deviceName(id)) [\(fourCC(transportType(id)))]"
                  + "\(hasInput(id) ? " input" : " output-only")"
                  + "\(blocked ? " BLOCKED" : "")")
            }
        }

        // Arrival records for devices that are gone are dead weight.
        for uid in removed { arrivals.removeValue(forKey: uid) }

        if state == .yielded {
            if let y = yieldedTo, !current.isEmpty, !current.contains(y) {
                // The device the user picked is gone; the yield has nothing to protect.
                //
                // Judged against the list as it is now, and never against an empty one. A list
                // with nothing in it is coreaudiod going away, not the device: four of the five
                // full rebuilds in the log came 2.4-3.5 s after the state went PINNED -> ABSENT
                // for want of any device. Expired there, the yield reached the rebuild with the
                // state already ABSENT, so the guard below never ran, and the user's choice was
                // reverted at every coreaudiod restart. `current` rather than `removed`, so a
                // device missing from the rebuilt list still ends the yield there — and so would
                // one that republished after the rebuild rather than in it. Every rebuild in the
                // log arrived whole; a piecemeal one has not been seen.
                yieldedTo = nil
                transition(.pinned, "yielded device disappeared")
            } else if !isRebuild, targetUIDs().contains(where: { added.contains($0) }) {
                // A genuine replug of the target clears the yield. A list rebuild must
                // not — that would erase a deliberate choice on every wake.
                yieldedTo = nil
                transition(.pinned, "target device re-arrived")
            }
        }

        applyPin(reason: "dev#")
    }

    func onDefaultInput() {
        // Diagnostic, 2026-09-11. Twice the default input sat on AirPods for over half an hour
        // with no line at all, and nothing could say whether this handler had even run. It says
        // so now, once per notification; the JUDGED lines in evaluate() say what was read.
        log("EVENT dIn  — default input changed")
        let now = Date()
        // Every notification used to reset the timer with no ceiling, so a burst
        // arriving faster than debounceMs could starve evaluate() indefinitely.
        // After 1s of continuous resetting, judge now instead.
        if let first = debounceFirstAt, now.timeIntervalSince(first) >= 1.0 {
            debounceItem?.cancel()
            debounceItem = nil
            debounceFirstAt = nil
            evaluate()
            return
        }
        if debounceFirstAt == nil { debounceFirstAt = now }
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.debounceFirstAt = nil
            self?.evaluate()
        }
        debounceItem = item
        work.asyncAfter(deadline: .now() + .milliseconds(config.debounceMs), execute: item)
    }

    /// Re-run the full judgment once, shortly. Used where an event would otherwise be
    /// dropped on the floor: the property read failed, or we suspect a notification was
    /// lost. One-shot and self-disarming, so idle stays at zero timers.
    func scheduleReconcile(_ why: String, after: Double) {
        guard !reconcileArmed else { return }
        reconcileArmed = true
        work.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self else { return }
            self.reconcileArmed = false
            self.evaluate(trigger: why)
        }
    }

    /// The trigger the one re-judgement for an unreadable default input carries, which is also
    /// how it is recognised. See `handleUnreadableDefault(_:)`.
    static let unreadableRetry = "unreadable default"

    /// The default input could not be read. Try once more, 2 s later — once: the retry carries
    /// its own trigger and arms no other. verification.md records this retry as "re-evaluates
    /// once after 2 s", and it re-armed itself instead, so a Mac with no input device at all —
    /// a Mac mini whose one microphone is unplugged — judged every 2 s and logged every time,
    /// for as long as that lasted, with no state change ever to truncate the log. The next audio
    /// event gets a retry of its own.
    ///
    /// The retry goes back the way it came. From applyPin() — `pinning` — it is applyPin()
    /// again, which judges no yield. It was a full evaluate(), so an unreadable moment after a
    /// SIGHUP could end in a yield to an input nobody chose: principle 4, and the reason the
    /// revert retry below goes through applyPin() as well.
    func handleUnreadableDefault(_ trigger: String, pinning: Bool = false) {
        guard trigger != Daemon.unreadableRetry else {
            log("default input still unreadable; waiting for the next audio event")
            return
        }
        log("default input unreadable; re-judging in 2s")
        guard pinning else {
            scheduleReconcile(Daemon.unreadableRetry, after: 2.0)
            return
        }
        guard !pinRetryArmed else { return }
        pinRetryArmed = true
        work.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.pinRetryArmed = false
            self.applyPin(reason: Daemon.unreadableRetry)
        }
    }

    /// One more attempt after CoreAudio refuses a write. Nothing else would make it: a refused
    /// set changes no property, so no 'dIn ' follows, and every timer in `revert(to:reason:)` is
    /// armed only by a write that succeeded — the wrong input stayed selected until some
    /// unrelated event came along. Through applyPin(), not evaluate(): the input still selected
    /// is not a choice anyone made, and evaluate() would take a non-Bluetooth one for exactly
    /// that and yield to it. One-shot, like the other re-judgements: the retry's own failure
    /// arms nothing.
    func retryRevertOnce() {
        guard !revertRetryArmed else { return }
        revertRetryArmed = true
        work.asyncAfter(deadline: .now() + config.reverifyDelaySeconds) { [weak self] in
            guard let self else { return }
            self.applyPin(reason: "revert retry")
            self.revertRetryArmed = false
        }
    }

    // MARK: Judgment

    func targetUIDs() -> [String] {
        config.input.priority.compactMap { $0.uid }
    }

    func resolveTarget() -> AudioDeviceID? {
        var deviceList: [AudioDeviceID]?
        for ref in config.input.priority {
            if let uid = ref.uid, let id = deviceID(forUID: uid), hasInput(id) { return id }
            if let name = ref.name {
                // Hoisted out of the loop: a name-based ref would otherwise re-enumerate
                // every device on every priority entry.
                let list = deviceList ?? allDevices()
                deviceList = list
                for id in list where hasInput(id) {
                    if deviceName(id) == name { return id }
                }
            }
        }
        return nil
    }

    /// True when a configured device is present but not yet reporting an input scope.
    /// hasInput() is a live HAL query and legitimately returns false while a device is
    /// still publishing its stream objects, so this is a transient to retry, not an
    /// absence to settle on — and nothing else would wake us if the scope appears
    /// without any change to the device list.
    func targetPendingInputScope() -> Bool {
        for ref in config.input.priority {
            if let uid = ref.uid, let id = deviceID(forUID: uid), !hasInput(id) { return true }
        }
        return false
    }

    func handleNoTarget(_ reason: String) {
        if targetPendingInputScope(), inputScopeRetries < Daemon.maxInputScopeRetries {
            guard !inputScopeRetryArmed else { return }
            inputScopeRetryArmed = true
            inputScopeRetries += 1
            log("target present but publishing no input scope yet; retry "
              + "\(inputScopeRetries)/\(Daemon.maxInputScopeRetries) in 1s")
            work.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.inputScopeRetryArmed = false
                self.applyPin(reason: "input-scope retry")
            }
            return
        }
        transition(.absent, reason)
    }

    /// Full judgment, including the yield decision. The 'dIn ' listener calls this, and so do
    /// the one-shot re-judgements; `trigger` names which, for the log and for nothing else.
    func evaluate(trigger: String = "dIn") {
        reloadConfigIfNeeded()
        guard config.enabled else { transition(.paused, "disabled in config"); return }
        guard let current = defaultInputDevice() else {
            // Returning here consumed the notification and nothing would ever retry.
            handleUnreadableDefault(trigger)
            return
        }

        if let e = expectedSelfWrite {
            if Date().timeIntervalSince(e.at) > config.postWriteGraceSeconds {
                // The notification for our write never arrived (HAL coalesces, and the
                // debounce cancels and reschedules). Drop the expectation rather than
                // let it swallow a genuine change later.
                expectedSelfWrite = nil
            } else if current == e.device {
                expectedSelfWrite = nil
                // One of the two exits that used to leave no line. With both silent, a
                // notification judged against a stale value looked exactly like one that never
                // arrived (docs/verification.md, Open issue); these lines tell the two apart.
                log("JUDGED (\(trigger)) \(deviceName(current)) — our own write "
                  + "\(String(format: "%.1f", Date().timeIntervalSince(e.at)))s ago; swallowed")
                return
            }
        }

        guard let target = resolveTarget() else {
            handleNoTarget("no configured input device present")
            return
        }
        inputScopeRetries = 0
        if current == target {
            // The other exit that used to be silent: with the state already PINNED the
            // transition below writes no line, so a stale read of the target left no trace.
            if state == .pinned {
                log("JUDGED (\(trigger)) \(deviceName(current)) — already the target")
            }
            transition(.pinned, "default input is the target")
            return
        }

        let name = deviceName(current)
        let tt = transportType(current)

        // Primary classification is transport type, not timing: AirPods complete HFP
        // (input) seconds after A2DP (output), which a timing window cannot survive.
        guard config.blockedTransports().contains(tt) else {
            yieldedTo = deviceUID(current)
            transition(.yielded, "user chose \(name) [\(fourCC(tt))] — respecting")
            return
        }

        // Bluetooth. Three independent pieces of evidence that this is the system
        // acting rather than a person choosing, weakest last:
        //  - flipBack: it moved right after our own write. Nobody re-picks a device in
        //    400ms, and the measured flip-back was 406ms and 436ms. Needs no history.
        //  - churn: we just started, or the HAL just reset, so macOS is re-deciding
        //    every default and we have nothing to compare against.
        //  - arrived: the device (or any blocked device) appeared moments ago.
        let now = Date()
        let flipBack = lastWriteAt.map {
            now.timeIntervalSince($0) < config.postWriteGraceSeconds
        } ?? false
        let churn = systemChurnUntil.map { now < $0 } ?? false
        let arrived = [deviceUID(current).flatMap { arrivals[$0] }, lastBlockedArrival]
            .compactMap { $0 }
            .contains { now.timeIntervalSince($0) < config.arrivalWindowSeconds }

        if flipBack || churn || arrived {
            let why = flipBack ? "flip-back" : (churn ? "system churn" : "auto-switch")
            revert(to: target, reason: "\(why) to \(name)")
        } else {
            yieldedTo = deviceUID(current)
            transition(.yielded, "user chose settled Bluetooth device \(name) — respecting")
        }
    }

    /// No yield judgment: used by device-list and recovery paths.
    func applyPin(reason: String) {
        reloadConfigIfNeeded()
        guard config.enabled else { transition(.paused, "disabled in config"); return }
        guard state != .yielded else { return }
        guard let target = resolveTarget() else {
            handleNoTarget("no configured input device present")
            return
        }
        inputScopeRetries = 0
        guard let current = defaultInputDevice() else {
            handleUnreadableDefault(reason, pinning: true)
            return
        }
        if current == target {
            transition(.pinned, reason)
            return
        }
        revert(to: target,
               reason: "\(reason), displacing \(deviceName(current)) "
                     + "[\(fourCC(transportType(current)))]")
    }

    func armSystemChurn(_ why: String) {
        systemChurnUntil = Date().addingTimeInterval(config.arrivalWindowSeconds)
        log("system churn window armed for \(Int(config.arrivalWindowSeconds))s (\(why))")
    }

    func revert(to target: AudioDeviceID, reason: String) {
        let now = Date()
        if let until = backoffUntil {
            if now < until {
                armBackoffWake(until)
                transition(.backoff, "holding off "
                         + "\(Int(until.timeIntervalSince(now)))s more — \(reason)")
                return
            }
            backoffUntil = nil
        }

        // Writes that took, not attempts. A write CoreAudio refused moves nothing, and counted, it
        // and its one retry left a third "revert" in five seconds to any unrelated event — a LOOP
        // GUARD blaming something else for a refusal. For writes that succeed this is the guard
        // it always was: the third inside five seconds is not made.
        revertTimes = revertTimes.filter { now.timeIntervalSince($0) < 5 }
        if revertTimes.count >= 2 {
            let until = now.addingTimeInterval(60)
            backoffUntil = until
            revertTimes.removeAll()
            armBackoffWake(until)
            // Made loud on purpose: a Continuity-poisoned HAL returns noErr while
            // reverting indefinitely, which would drain this guard invisibly.
            transition(.backoff, "LOOP GUARD — 3 reverts in 5s, standing down 60s. "
                               + "Something else is contending for the default input.")
            return
        }

        expectedSelfWrite = (target, now)
        let st = setDefaultInputDevice(target)
        guard st == noErr else {
            expectedSelfWrite = nil
            log("REVERT FAILED status=\(osStatusText(st))")
            retryRevertOnce()
            return
        }
        revertTimes.append(now)
        lastWriteAt = now
        log("REVERT -> \(deviceName(target)) (\(reason))")
        transition(.pinned, reason)

        // The set is asynchronous. One re-verify closes the only real hole:
        // a re-assertion swallowed inside the debounce window.
        work.asyncAfter(deadline: .now() + config.reverifyDelaySeconds) { [weak self] in
            guard let self, self.state == .pinned else { return }
            // Resolved again rather than captured (CLAUDE.md, principle 3). A second has passed,
            // and in it the config can have named another device, or this one been replugged
            // under a reused ID — writing the captured one would select whatever holds it now.
            guard let target = self.resolveTarget(),
                  let cur = defaultInputDevice(), cur != target else { return }
            let at = Date()
            self.expectedSelfWrite = (target, at)
            let st = setDefaultInputDevice(target)
            guard st == noErr else {
                self.expectedSelfWrite = nil
                log("RE-VERIFY FAILED status=\(osStatusText(st))")
                return
            }
            // Must advance lastWriteAt: the flip-back grace is measured from the most
            // recent write, and leaving it at the original one made the window depend
            // on reverifyDelaySeconds staying well below postWriteGraceSeconds.
            self.lastWriteAt = at
            log("RE-VERIFY -> \(deviceName(target)) (default did not stick)")
        }

        // A second, later look. Observed once: the default sat on the AirPods for ~1.5h
        // after a successful revert with no log line at all — no sleep, no coreaudiod
        // restart, no crash, and the listener proved alive afterwards, so the most
        // likely explanation left is a lost notification. The cause was never pinned
        // down, so this is insurance, not a fix: one extra judgment while the evidence
        // is still inside the arrival window. Self-disarming, no steady-state cost.
        //
        // It happened again on 2026-09-11 for 42 minutes, and this look had run and read the
        // target: the switch came after it. Nor is a lost notification the only explanation —
        // the JUDGED lines in evaluate() exist to decide the next one.
        scheduleReconcile("post-revert settle", after: 5.0)
    }

    /// Nothing else would re-apply the pin when a backoff expires, and the wrong mic
    /// would simply stay wrong until an unrelated audio event happened to arrive.
    func armBackoffWake(_ until: Date) {
        guard !backoffWakeArmed else { return }
        backoffWakeArmed = true
        work.asyncAfter(deadline: .now() + max(0.5, until.timeIntervalSinceNow + 0.5)) {
            [weak self] in
            guard let self else { return }
            self.backoffWakeArmed = false
            self.backoffUntil = nil
            log("backoff expired; re-applying the pin")
            self.applyPin(reason: "backoff expired")
        }
    }

    func transition(_ new: State, _ why: String) {
        let changed = state != new
        if changed {
            // Rotate before appending so this line survives the truncation.
            truncateLogIfLarge()
            log("\(state.rawValue) -> \(new.rawValue): \(why)")
            state = new
        }
        // Refresh the state file whenever anything a reader would notice changed —
        // the state itself or the reason. Writing unconditionally is what turned a
        // flapping device into thousands of identical file writes; gating on the
        // reason still fixes the stale-hold bug this replaced, because `micpeg on`
        // always arrives with a new reason.
        guard changed || why != lastWrittenReason else { return }
        // Recorded once it is on disk, not before. Set first, a write that failed was never
        // tried again: the next transition with the same state and reason found it written.
        if writeState(reason: why) { lastWrittenReason = why }
    }

    // MARK: Bookkeeping

    func snapshotDevices() {
        var uids: Set<String> = []
        var inputs: Set<String> = []
        for id in allDevices() {
            guard let uid = deviceUID(id) else { continue }
            uids.insert(uid)
            if hasInput(id) { inputs.insert(uid) }
        }
        knownUIDs = uids
        inputCapableUIDs = inputs
    }

    func reloadConfigIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configPath.path)
        let m = attrs?[.modificationDate] as? Date
        guard m != configMTime || !configEverLoaded else { return }
        configMTime = m

        switch Config.read() {
        case .ok(let c):
            config = c
            configEverLoaded = true
            log("config loaded (\(c.input.priority.count) priority entries, "
              + "block=\(c.blockTransports.joined(separator: ",")))")
            c.reportBlocklistProblems { log($0) }
        case .missing:
            config = .fallback
            configEverLoaded = true
            log("no config at \(configPath.path); using defaults with no target — "
              + "run `micpeg pick` to choose one")
        case .corrupt(let why):
            // Keep whatever we already had. Falling back would replace a good target
            // list with an empty one and silently unpin everything.
            log("WARNING: config is malformed, keeping the settings already in memory: \(why)")
        }
    }

    /// True when the file is on disk. `transition()` records the reason only then.
    @discardableResult
    func writeState(reason: String) -> Bool {
        let target = resolveTarget().map { deviceName($0) } ?? "(absent)"
        let cur = defaultInputDevice().map { deviceName($0) } ?? "(none)"
        let sf = StateFile(state: state.rawValue, reason: reason, target: target,
                           currentInput: cur,
                           updated: stampFormatter.string(from: Date()))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try enc.encode(sf).write(to: statePath, options: .atomic)
            stateWriteFailed = false
            return true
        } catch {
            // Logged once per failure run: silently dropping this made `micpeg status`
            // claim the daemon had never run while it was pinning correctly.
            if !stateWriteFailed {
                stateWriteFailed = true
                log("WARNING: cannot write \(statePath.path): \(error) — `micpeg status` "
                  + "will report stale state until this is fixed")
            }
            return false
        }
    }

    func run() {
        truncateLogIfLarge()
        log("micpeg starting (pid \(getpid()))")
        reloadConfigIfNeeded()
        registerAll()
        snapshotDevices()
        // Startup needs the same grace a HAL reset gets: nothing here is an "arrival"
        // (snapshotDevices records none) and no write has happened, so a Bluetooth mic
        // already connected at login would grab the input seconds later with no
        // evidence to appeal to, and the daemon would read it as a deliberate choice.
        armSystemChurn("daemon start")
        applyPin(reason: "startup")
    }
}

func truncateLogIfLarge() {
    let p = logPath.path
    if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
       let size = attrs[.size] as? UInt64, size > 256 * 1024 {
        truncate(p, 0)
    }
}

// MARK: - launchctl

func runTool(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

var serviceTarget: String { "gui/\(getuid())/\(agentLabel)" }

func nudgeDaemon() {
    let (st, out) = runTool("/bin/launchctl", ["kill", "SIGHUP", serviceTarget])
    if st != 0 {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        print("note: could not signal the daemon (\(trimmed.isEmpty ? "status \(st)" : trimmed))")
        print("      it will pick the change up on its next audio event regardless.")
    }
}

// MARK: - CLI helpers

/// CLI paths must never write over a config they could not parse — that is how a
/// half-edited file turns into permanent loss of the pinned target list.
func configForMutation() -> Config {
    switch Config.read() {
    case .missing:
        return .fallback
    case .ok(let c):
        return c
    case .corrupt(let why):
        print("error: \(configPath.path) is malformed:")
        print("       \(why)")
        print("refusing to overwrite it. Fix the file, or delete it to start fresh.")
        exit(1)
    }
}

func warnIfTargetIsBlocked(_ id: AudioDeviceID, _ cfg: Config) {
    let tt = transportType(id)
    guard cfg.blockedTransports().contains(tt) else { return }
    print("warning: \(deviceName(id)) is a [\(fourCC(tt))] device and [\(fourCC(tt))] is on")
    print("         blockTransports, so this pin can never be enforced — the daemon")
    print("         treats that transport as an automatic switch to undo.")
    print("         Pin a different device, or drop that transport from the list.")
}

func xmlEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

/// launchd needs an absolute path that actually exists; argv[0] may be relative or
/// resolved through PATH.
func runningExecutable() -> URL? {
    let fm = FileManager.default
    if let u = Bundle.main.executableURL, fm.isExecutableFile(atPath: u.path) {
        return u.resolvingSymlinksInPath()
    }
    let a0 = CommandLine.arguments[0]
    let u = a0.hasPrefix("/")
        ? URL(fileURLWithPath: a0)
        : URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(a0)
    return fm.isExecutableFile(atPath: u.path) ? u.resolvingSymlinksInPath() : nil
}

/// The .app enclosing an executable, if there is one.
func enclosingAppBundle(of executable: URL) -> URL? {
    var dir = executable.deletingLastPathComponent()
    while dir.path != "/" {
        if dir.pathExtension == "app" { return dir }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

/// The .app enclosing the running executable, if there is one.
///
/// runningExecutable() resolves symlinks, and that is load-bearing rather than tidy:
/// measured on macOS 26, running the CLI through a symlink in ~/.local/bin leaves
/// Bundle.main.bundlePath pointing at ~/.local/bin, not at the app. A check that
/// skipped the resolution would miss precisely the case this exists to catch — a user
/// with the bundled CLI on their PATH.
func enclosingAppBundle() -> URL? {
    runningExecutable().flatMap(enclosingAppBundle(of:))
}

/// Whether the agent holding the label is the one Micpeg.app registered, whichever copy of
/// micpeg is asking. Two signals, and either is enough, because refusing is the safe direction:
/// launchd's `managed_by`, which it prints for a ServiceManagement job and leaves out for a
/// hand-written one (docs/verification.md §9), and the running daemon's own executable, when it
/// sits inside an .app. The second also names the app, for the message.
func agentRegisteredByApp() -> (registered: Bool, app: URL?) {
    let (st, out) = runTool("/bin/launchctl", ["print", serviceTarget])
    guard st == 0 else { return (false, nil) }
    let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    var app: URL?
    if let pid = lines.first(where: { $0.hasPrefix("pid = ") })
        .flatMap({ pid_t($0.dropFirst("pid = ".count)) }) {
        var path = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            app = enclosingAppBundle(of: URL(fileURLWithPath: String(cString: path)))
        }
    }
    return (lines.contains("managed_by = com.apple.xpc.ServiceManagement") || app != nil, app)
}

/// One registration path, enforced rather than documented. `micpeg install` writes the
/// legacy plist under the same label the app registers through SMAppService, and the
/// collision that follows is silent in both directions — measured, docs/verification.md.
/// The app cannot see the plist unless it goes looking for it, and launchd will not
/// honour the plist while a Background Task Management record holds the label.
///
/// There are two ways to be the wrong copy, and this used to check only one: where this binary
/// lives. A copy outside the app — the one scripts/install.sh builds, or the legacy
/// ~/.local/bin/micpeg that migration deliberately leaves in place — passed, and README's own
/// Updating and Uninstall steps then booted the app's agent out. Who holds the label is the
/// other half.
func refuseIfTheAppManagesTheAgent(_ command: String) {
    if let app = enclosingAppBundle() {
        let appName = app.lastPathComponent
        print("error: this copy of micpeg lives inside \(appName), which registers the")
        print("       background agent itself. `micpeg \(command)` manages the separate,")
        print("       hand-written LaunchAgent under the same label, and one label cannot")
        print("       have two registration paths. The collision is silent: nothing would")
        print("       report an error and the microphone would quietly stop being pinned.")
        print("       Open \(appName) to turn the agent on or off.")
        exit(1)
    }
    let holder = agentRegisteredByApp()
    guard holder.registered else { return }
    let appName = holder.app?.lastPathComponent ?? "Micpeg.app"
    print("error: the background agent on this Mac was registered by \(appName).")
    print("       `micpeg \(command)` manages the separate, hand-written LaunchAgent under")
    print("       the same label, and running it would boot the app's agent out. Use")
    print("       \(appName) instead, or remove it in System Settings > General >")
    print("       Login Items & Extensions. If the app has already been deleted, its agent")
    print("       can outlive it (docs/verification.md §3); `launchctl bootout \(serviceTarget)`")
    print("       clears that.")
    exit(1)
}

// MARK: - Subcommands

func cmdList() {
    let current = defaultInputDevice()
    print("input devices:")
    for id in allDevices() where hasInput(id) {
        let mark = id == current ? "*" : " "
        let uid = deviceUID(id) ?? "?"
        print("  \(mark) \(deviceName(id))")
        print("      transport=\(fourCC(transportType(id)))  uid=\(uid)")
    }
    print("\n(* = current default input)")
}

func cmdStatus() {
    var cfg = Config.fallback
    switch Config.read() {
    case .ok(let c):
        cfg = c
        print("enabled:       \(c.enabled)")
        c.reportBlocklistProblems { print("               \($0)") }
    case .missing:
        print("enabled:       (no config — run: micpeg install)")
    case .corrupt(let why):
        // Not "its last good settings": that is true of a daemon that loaded a good file
        // before this one broke, and false of one started since, which holds Config.fallback
        // and no target (`reloadConfigIfNeeded()`).
        print("enabled:       CONFIG MALFORMED — \(why)")
        print("               the daemon keeps the settings it last loaded — none, if it")
        print("               has restarted since; fix or delete \(configPath.path)")
    }

    let cur = defaultInputDevice()
    print("default input: \(cur.map { "\(deviceName($0)) [\(fourCC(transportType($0)))]" } ?? "(none)")")

    if cfg.input.priority.isEmpty {
        print("target:        (none configured — run: micpeg pick)")
    } else {
        for (i, ref) in cfg.input.priority.enumerated() {
            let resolved = ref.uid.flatMap { deviceID(forUID: $0) }
            let present = resolved.map { hasInput($0) ? "present" : "no input scope" } ?? "absent"
            print("target[\(i)]:     \(ref.name ?? ref.uid ?? "?")  — \(present)")
        }
    }

    if let data = try? Data(contentsOf: statePath),
       let sf = try? JSONDecoder().decode(StateFile.self, from: data) {
        print("state:         \(sf.state)  (\(sf.reason))")
        print("updated:       \(sf.updated)")
    } else {
        print("state:         (no state file — daemon has not run yet)")
    }

    let (st, out) = runTool("/bin/launchctl", ["print", serviceTarget])
    if st == 0, let line = out.split(separator: "\n").first(where: { $0.contains("pid = ") }) {
        print("daemon:        \(line.trimmingCharacters(in: .whitespaces))")
    } else {
        print("daemon:        not loaded")
    }
}

func cmdEnable(_ on: Bool) {
    var cfg = configForMutation()
    cfg.enabled = on
    do { try cfg.save() } catch {
        print("error: could not write config: \(error)"); exit(1)
    }
    print(on ? "micpeg enabled" : "micpeg paused")
    nudgeDaemon()
}

/// `micpeg pick` captures the current default input; `micpeg pick <uid>` names a device
/// directly, which is how the app pins the one the user chose in its device sheet.
func cmdPick(_ requestedUID: String?) {
    let id: AudioDeviceID
    let uid: String
    if let want = requestedUID {
        // Resolve through 'uidd' rather than trusting the string: the app and the daemon
        // then agree by construction, and a UID that does not resolve simply means the
        // device is not here right now.
        guard let resolved = deviceID(forUID: want) else {
            print("error: no connected device has uid \(want)")
            print("       run `micpeg list` to see what is connected.")
            exit(1)
        }
        // resolveTarget() requires an input scope, so pinning an output-only device is
        // accepted and then never enforced — the daemon would sit in ABSENT for good.
        // Refuse instead of producing a pin that cannot act.
        guard hasInput(resolved) else {
            print("error: \(deviceName(resolved)) publishes no input scope, so pinning it")
            print("       would leave the daemon with nothing to enforce.")
            exit(1)
        }
        id = resolved
        // Store what the device calls itself, not what the caller typed.
        uid = deviceUID(resolved) ?? want
    } else {
        guard let current = defaultInputDevice() else {
            print("error: no default input device to capture"); exit(1)
        }
        guard let currentUID = deviceUID(current) else {
            print("error: device has no UID; refusing to pin by name alone"); exit(1)
        }
        id = current
        uid = currentUID
    }
    let name = deviceName(id)
    var cfg = configForMutation()
    warnIfTargetIsBlocked(id, cfg)
    // The pick replaces the list; it used to move to the front of it. Kept, every earlier pick
    // became a fallback nobody chose: the app names one microphone, so after Change Microphone
    // the one it replaced went on being forced whenever the new one was unplugged — README's
    // "does not force a fallback", broken by the command it documents. A chain is still a
    // hand edit of `input.priority` away, and this says what it dropped from one.
    let dropped = cfg.input.priority.filter { $0.uid != uid }
    cfg.input.priority = [DeviceRef(uid: uid, name: name)]
    do { try cfg.save() } catch {
        print("error: could not write config: \(error)"); exit(1)
    }
    print("pinned to: \(name)")
    print("uid:       \(uid)")
    if !dropped.isEmpty {
        print("replaced:  \(dropped.map { $0.name ?? $0.uid ?? "?" }.joined(separator: ", "))")
    }
    nudgeDaemon()
}

/// Put `micpeg` on the user's PATH, pointing at this binary. Invoked by the app;
/// optional for the user.
///
/// A symlink rather than a copy. An app update replaces the executable inside the
/// bundle, and a copy would keep serving the old one — the same staleness that forced
/// scripts/install.sh to stage the binary itself because `micpeg install` only copies
/// when the destination is missing.
func cmdLink(force: Bool) {
    let fm = FileManager.default
    guard let src = runningExecutable() else {
        print("error: could not locate the running micpeg binary to link to."); exit(1)
    }
    let dest = binPath
    let dir = dest.deletingLastPathComponent()

    // lstat, not FileManager.fileExists: fileExists follows symlinks, so a link left
    // dangling by a deleted app reads as "nothing there" and the create below then
    // fails with EEXIST. lstat sees the link itself.
    var info = stat()
    let present = lstat(dest.path, &info) == 0
    let isSymlink = present && (info.st_mode & S_IFMT) == S_IFLNK

    // --force removes what is in the way, and a directory is the one thing it must never
    // remove: this command promises a symlink, not a recursive delete.
    if present && (info.st_mode & S_IFMT) == S_IFDIR {
        print("error: \(dest.path) is a directory. Refusing to touch it."); exit(1)
    }

    if present && !isSymlink && !force {
        // A regular file here is the legacy install — a real binary that launchd may
        // still be running. Replacing it unasked is how an upgrade silently breaks a
        // setup that was working.
        print("error: \(dest.path) already exists and is not a symlink.")
        print("       That is most likely the standalone CLI install. Re-run with")
        print("       --force to replace it with a link to this binary.")
        exit(1)
    }

    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if present { try fm.removeItem(at: dest) }
        try fm.createSymbolicLink(at: dest, withDestinationURL: src)
    } catch {
        print("error: could not link \(dest.path): \(error)"); exit(1)
    }
    print("linked \(dest.path) -> \(src.path)")

    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    if !path.split(separator: ":").contains(where: { String($0) == dir.path }) {
        print("note: \(dir.path) is not on your PATH — add it to run `micpeg` directly.")
    }
}

func cmdInstall() {
    refuseIfTheAppManagesTheAgent("install")
    let fm = FileManager.default

    // launchd would otherwise crash-loop forever on a path that does not exist while
    // install reported success, with no log file to point at the cause.
    if !fm.isExecutableFile(atPath: binPath.path) {
        guard let src = runningExecutable() else {
            print("error: no micpeg binary at \(binPath.path), and the running binary")
            print("       could not be located to copy. Put it there and re-run install.")
            exit(1)
        }
        do {
            try fm.createDirectory(at: binPath.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: binPath)
            print("copied \(src.path) -> \(binPath.path)")
        } catch {
            print("error: could not install the binary at \(binPath.path): \(error)"); exit(1)
        }
    }

    if !fm.fileExists(atPath: configPath.path) {
        var cfg = Config.fallback
        if let id = defaultInputDevice(), let uid = deviceUID(id) {
            cfg.input.priority = [DeviceRef(uid: uid, name: deviceName(id))]
            print("seeded target from current default input: \(deviceName(id))")
            warnIfTargetIsBlocked(id, cfg)
        } else {
            print("warning: no default input device found; run 'micpeg pick' after install")
        }
        do { try cfg.save() } catch {
            print("error: could not write config: \(error)"); exit(1)
        }
        print("wrote \(configPath.path)")
    }

    try? fm.createDirectory(at: plistPath.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    try? fm.createDirectory(at: logPath.deletingLastPathComponent(),
                            withIntermediateDirectories: true)

    // ProcessType Background: unspecified would let the system apply arbitrary
    // light resource limits. KeepAlive plain true, ThrottleInterval 60 so a crash
    // loop cannot become a battery drain. Logging via StandardErrorPath rather than
    // os_log so the user can just tail it.
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>              <string>\(xmlEscaped(agentLabel))</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(xmlEscaped(binPath.path))</string>
            <string>daemon</string>
        </array>
        <key>RunAtLoad</key>          <true/>
        <key>KeepAlive</key>          <true/>
        <key>ThrottleInterval</key>   <integer>60</integer>
        <key>ProcessType</key>        <string>Background</string>
        <key>StandardErrorPath</key>  <string>\(xmlEscaped(logPath.path))</string>
    </dict>
    </plist>
    """
    do { try plist.write(to: plistPath, atomically: true, encoding: .utf8) } catch {
        print("error: could not write plist: \(error)"); exit(1)
    }
    print("wrote \(plistPath.path)")

    // launchctl load is legacy on macOS 26; bootstrap/bootout is the current pair.
    // bootout tears down asynchronously, so bootstrap can lose the race with
    // "Operation already in progress" — retry rather than fail the install.
    _ = runTool("/bin/launchctl", ["bootout", serviceTarget])
    var st: Int32 = -1
    var out = ""
    for attempt in 1...5 {
        (st, out) = runTool("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath.path])
        if st == 0 { break }
        if attempt < 5 { usleep(400_000) }
    }
    if st == 0 {
        print("bootstrapped \(serviceTarget)")
    } else {
        print("error: bootstrap failed (status \(st)): \(out)"); exit(1)
    }
}

func cmdUninstall() {
    refuseIfTheAppManagesTheAgent("uninstall")
    let (st, out) = runTool("/bin/launchctl", ["bootout", serviceTarget])
    print(st == 0 ? "booted out \(serviceTarget)"
                  : "note: bootout returned \(st): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    for f in [plistPath, statePath] {
        if (try? FileManager.default.removeItem(at: f)) != nil {
            print("removed \(f.path)")
        }
    }
    print("kept \(configPath.path) and \(logPath.path)")
    print("remove the binary with: rm \(binPath.path)")
}

func cmdDaemon() {
    redirectStderrToLogIfDiscarded()
    setvbuf(stderr, nil, _IOLBF, 0)

    let daemon = Daemon()

    // SIG_IGN first: the dispatch source observes, it does not change disposition.
    signal(SIGHUP, SIG_IGN)
    let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: daemon.work)
    hup.setEventHandler {
        log("SIGHUP — reloading config")
        daemon.configMTime = nil
        daemon.configEverLoaded = false
        daemon.reloadConfigIfNeeded()
        // An explicit `micpeg on` is the user's remedy for every hold, so it has to
        // clear all of them — a backoff left in place made the command inert while
        // the mic stayed wrong.
        //
        // PAUSED is left for applyPin() to leave, which it does with a line saying so. Reset
        // here without one, the log never said PAUSED had ended: a pick while paused came out
        // as `ABSENT -> PAUSED`, which Activity could only read as the user pausing again, and
        // a resume with the kept microphone unplugged wrote nothing at all. applyPin() stops
        // only at YIELDED, so it needs no reset to act from PAUSED.
        if daemon.state == .yielded || daemon.state == .backoff {
            daemon.state = .absent
            daemon.yieldedTo = nil
        }
        daemon.backoffUntil = nil
        daemon.revertTimes.removeAll()
        daemon.inputScopeRetries = 0
        daemon.applyPin(reason: "SIGHUP")
    }
    hup.resume()

    daemon.work.async { daemon.run() }

    // CFRunLoopRun(), never dispatchMain(): the HAL attaches its notification source
    // to CFRunLoopGetMain(), and dispatchMain() pthread_exit()s the main thread,
    // leaving that run loop existing but unserviced — every listener, including the
    // 'srst' recovery listener, would then never fire. A run loop with no timers and
    // no scheduled sources blocks in mach_msg with no timeout, so this costs no wakeups.
    CFRunLoopRun()

    log("run loop returned unexpectedly; exiting")
    exit(1)
}

func usage() {
    print("""
    micpeg — pins the macOS default audio input device

    usage: micpeg <command>

      status      show current state, target and daemon liveness
      list        list input devices with transport type and UID
      pick [uid]  pin the given device, or the current default input
      on | off    resume / pause pinning
      link        put micpeg on your PATH as a link to this binary (--force replaces
                  an existing file at ~/.local/bin/micpeg)
      install     write config + LaunchAgent and bootstrap the daemon
      uninstall   bootout the daemon and remove its LaunchAgent
      daemon      run in the foreground (used by launchd)
    """)
}

// MARK: - Entry

switch CommandLine.arguments.dropFirst().first {
case "daemon":    cmdDaemon()
case "status":    cmdStatus()
case "list":      cmdList()
case "pick":      cmdPick(CommandLine.arguments.dropFirst(2).first)
case "on":        cmdEnable(true)
case "off":       cmdEnable(false)
case "link":      cmdLink(force: CommandLine.arguments.dropFirst(2).contains("--force"))
case "install":   cmdInstall()
case "uninstall": cmdUninstall()
case nil:         cmdStatus()
case let other:
    print("unknown command: \(other ?? "")")
    usage()
    exit(2)
}
