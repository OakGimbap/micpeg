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
    /// The four-character transport code as the CLI prints it: `usb `, `bltn`, `blue`.
    public var transport: String
    public var hasInput: Bool

    public init(id: AudioDeviceID, uid: String?, name: String, transport: String, hasInput: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
    }
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
    static let aggregateTransport = fourCC(kAudioDeviceTransportTypeAggregate)

    /// Every device that publishes an input scope and is something a person could mean by
    /// "my microphone", in the order CoreAudio reports them.
    public static func inputDevices() -> [AudioDevice] {
        allDevices().compactMap { id in
            guard hasInput(id) else { return nil }
            guard fourCC(transportType(id)) != aggregateTransport else { return nil }
            return AudioDevice(id: id,
                               uid: deviceUID(id),
                               name: deviceName(id),
                               transport: fourCC(transportType(id)),
                               hasInput: true)
        }
    }

    public static func currentInput() -> AudioDevice? {
        defaultInputDevice().map {
            AudioDevice(id: $0, uid: deviceUID($0), name: deviceName($0),
                        transport: fourCC(transportType($0)), hasInput: hasInput($0))
        }
    }

    /// Displayed, never touched. See the header, and the invariant that depends on this call
    /// being in this target.
    public static func currentOutput() -> AudioDevice? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return AudioDevice(id: id, uid: deviceUID(id), name: deviceName(id),
                           transport: fourCC(transportType(id)), hasInput: hasInput(id))
    }

    /// Whether a device sits on a transport the daemon is configured to refuse. Pinning one
    /// produces an agent that can never act — the CLI warns about it in
    /// `warnIfTargetIsBlocked()`, and app-ui.md requires the window to match that behaviour
    /// rather than silently accept the choice.
    public static func isBlocked(_ device: AudioDevice, by blocked: [String]) -> Bool {
        blocked.contains { name in
            guard let code = transportCode(name) else { return false }
            return fourCC(code) == device.transport
        }
    }
}

/// The three HAL properties the window cares about, watched only while it is on screen.
///
/// `AudioObjectAddPropertyListenerBlock` rather than the C function-pointer form: the block
/// form takes a dispatch queue, so the callback arrives somewhere known instead of on whatever
/// thread the HAL happens to use.
public final class DeviceWatch {
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "com.micpeg.app.devices")
    private var installed: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var coalesce: DispatchWorkItem?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        // dev# — devices appearing and disappearing.
        // dIn  — the default input moving, which is the event the whole program exists for.
        // dOut — the default output moving, which the window displays.
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            install(addr(selector))
        }
    }

    deinit {
        for (address, block) in installed {
            var a = address
            AudioObjectRemovePropertyListenerBlock(systemObject, &a, queue, block)
        }
    }

    private func install(_ address: AudioObjectPropertyAddress) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fire() }
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &a, queue, block)
        // A listener that failed to install is the exact shape of this project's favourite
        // silent failure: the window would simply stop updating, with nothing to read.
        guard status == noErr else {
            assertionFailure("could not watch \(fourCC(address.mSelector)): \(osStatusText(status))")
            return
        }
        installed.append((address, block))
    }

    /// One redraw per burst. A revert moves the default input twice, roughly 400 ms apart —
    /// the daemon's 300 ms debounce plus its re-verify — and the window should settle once.
    private func fire() {
        coalesce?.cancel()
        let work = DispatchWorkItem { [onChange] in
            Task { @MainActor in onChange() }
        }
        coalesce = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
