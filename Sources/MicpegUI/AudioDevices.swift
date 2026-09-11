// What the window shows about audio, and how it notices changes while it is open.
//
// Two rules from docs/app-design.md govern this file, and both are enforced by greps in
// scripts/invariants.sh rather than by discipline:
//
//   1. **The app writes nothing to CoreAudio.** There is exactly one call to
//      AudioObjectSetPropertyData in the whole project and it lives in the daemon target.
//      Everything here reads, or installs a listener, which is not a write.
//
//   2. **The default output is read here, not in MicpegAudio.** The daemon links MicpegAudio,
//      and "micpeg never touches your speakers" is kept honest by a grep for
//      DefaultOutputDevice across everything the daemon links. The window has to display the
//      output device, so that one read lives in this target, where the daemon cannot reach it.
//
// The listeners exist only while the window is open. The daemon owns the always-on watching;
// duplicating it here for a window nobody is looking at would be a second set of HAL callbacks
// running for no reason.

import CoreAudio
import Foundation
import MicpegAudio

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public var id: AudioDeviceID
    public var uid: String?
    public var name: String
    /// The raw CoreAudio transport type. Kept alongside the display string so comparisons are
    /// integer ones: the first draft compared four-character *strings* — including a literal
    /// `"bltn"` written out by hand in AppModel — which rebuilt a `[UInt8]` and a `String` for
    /// every device on every redraw, and put the one hand-typed transport code in the project
    /// somewhere the compiler could not check it.
    public var transportCode: UInt32
    /// The same code as the CLI prints it: `usb `, `bltn`, `blue`. Display only.
    public var transport: String

    public init(id: AudioDeviceID, uid: String?, name: String, transportCode: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transportCode = transportCode
        self.transport = fourCC(transportCode)
    }

    public var isBuiltIn: Bool { transportCode == kAudioDeviceTransportTypeBuiltIn }
}

public enum AudioSnapshot {
    /// Aggregate devices, hidden from the window's list.
    ///
    /// Not a style choice. Measured: while the input test holds the default input open, the
    /// HAL publishes a transient `CADefaultDeviceAggregate-<pid>-<n>` that has an input scope
    /// and so appeared in the picker as something to choose — created by the app's own Start
    /// Test button, gone again when the test stopped. Any application using the microphone
    /// produces one, so this is not specific to micpeg.
    ///
    /// The cost is that a deliberately built Aggregate Device is hidden too. That is the right
    /// trade for a window whose audience is "my AirPods keep stealing my microphone", and it
    /// is not a dead end: `micpeg list` still shows them and `micpeg pick <uid>` still pins
    /// one, so the pro-audio case has a route that the ordinary case cannot stumble into.

    /// One device, read once. Every property this needs comes from `MicpegAudio`; the point of
    /// having it in one place is that the three callers below cannot drift, and that
    /// `transportType` is asked for once rather than once to filter and again to store.
    static func device(_ id: AudioDeviceID) -> AudioDevice {
        AudioDevice(id: id, uid: deviceUID(id), name: deviceName(id),
                    transportCode: transportType(id))
    }

    /// Every device that publishes an input scope and is something a person could mean by
    /// "my microphone", in the order CoreAudio reports them.
    public static func inputDevices() -> [AudioDevice] {
        allDevices()
            .filter { hasInput($0) }
            .map(device(_:))
            .filter { $0.transportCode != kAudioDeviceTransportTypeAggregate }
    }

    public static func currentInput() -> AudioDevice? {
        defaultInputDevice().map(device(_:))
    }

    /// Displayed, never touched. See the header, and the invariant that depends on this call
    /// being in this target.
    public static func currentOutput() -> AudioDevice? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return device(id)
    }
}

/// The three HAL properties the window cares about, watched only while it is on screen.
///
/// `AudioObjectAddPropertyListenerBlock` rather than the C function-pointer form: the block
/// form takes a dispatch queue, so the callback arrives somewhere known instead of on whatever
/// thread the HAL happens to use.
public final class DeviceWatch {
    private let queue = DispatchQueue(label: "com.micpeg.app.devices")
    private var installed: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let coalescer: Coalescer

    /// Called on the main actor, like everything below that touches `installed`: `AppModel`
    /// creates and releases this there, and a coreaudiod restart hops there to reinstall.
    public init(onChange: @escaping @MainActor () -> Void) {
        self.coalescer = Coalescer(delay: DaemonTiming.coalesce, onFire: onChange)
        installAll()
    }

    deinit {
        coalescer.cancel()
        removeAll()
    }

    // dev# — devices appearing and disappearing.
    // dIn  — the default input moving, which is the event the whole program exists for.
    // dOut — the default output moving, which the window displays.
    // srst — coreaudiod restarting. AudioHardware.h: a client must re-establish its "added
    //        listeners" afterwards (design.md, trap 2), and the daemon does; the window did not,
    //        so a restart while it was open could leave it drawing what it last read.
    private func installAll() {
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            install(addr(selector)) { [weak self] in self?.coalescer.schedule() }
        }
        install(addr(kAudioHardwarePropertyServiceRestarted)) { [weak self] in
            // Off this queue before touching the listeners: this block is one of the deliveries
            // on it, and the daemon keeps teardown off its delivery queue for the same reason
            // (`Daemon.work`).
            DispatchQueue.main.async { self?.reinstall() }
        }
    }

    private func reinstall() {
        removeAll()
        installAll()
        // Everything is read again. Whatever changed while the listeners were dead said nothing.
        // Scheduled from `queue`, the one queue `coalescer` is driven from.
        queue.async { [weak self] in self?.coalescer.schedule() }
    }

    private func removeAll() {
        for (address, block) in installed {
            var a = address
            AudioObjectRemovePropertyListenerBlock(systemObject, &a, queue, block)
        }
        installed.removeAll()
    }

    private func install(_ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &a, queue, block)
        // A listener that failed to install is the exact shape of this project's favourite
        // silent failure: the window would simply stop updating, with nothing to read.
        guard status == noErr else {
            assertionFailure("could not watch \(fourCC(address.mSelector)): \(osStatusText(status))")
            return
        }
        installed.append((address, block))
    }
}
