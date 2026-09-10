// The input test: open the microphone, measure it, and show the user it is the right one.
//
// This is the only place in the project that opens an audio stream, and it is why
// `scripts/invariants.sh` greps for AVFoundation in the *daemon's* sources — so the README's
// "the background agent never opens your microphone" stays literally true now that the app can.
//
// Three facts here come from AVFAudio's own headers, not from recollection:
//
//   - AVAudioEngineConfigurationChangeNotification — "When the engine's I/O unit observes a
//     change to the audio input or output hardware's channel count or sample rate, the engine
//     stops itself and issues this notification." So a device change does not merely disturb
//     the meter; it stops the engine, and nothing restarts it but us.
//
//   - "the engine must not be deallocated from within the client's notification handler
//     because the callback happens on an internal dispatch queue and can deadlock while trying
//     to synchronously teardown the engine." The handler below therefore does nothing but hop
//     to the main actor.
//
//   - "Only one tap may be installed on any bus. Taps may be safely installed and removed
//     while the engine is running." Hence removeTap before every install.
//
// The engine follows the system default input and offers no device selection of its own. That
// is deliberate (app-ui.md): the test has to exercise the same path every other application
// uses, because that path is exactly what is being verified.

import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
public final class InputTest {
    /// Roughly two seconds of history at 30 Hz.
    public static let slots = 64

    /// Below this, nothing is arriving. See the measurements in `sample()`.
    public static let silenceThreshold: Float = 0.0005

    public private(set) var isRunning = false
    public private(set) var levels = [Float](repeating: 0, count: InputTest.slots)
    public private(set) var isSilent = false
    public private(set) var failure: String?

    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var restart: DispatchWorkItem?
    private var quietSince: Date?

    /// Written from the audio thread, read from the main actor. A tap callback must not touch
    /// observable state — SwiftUI would be asked to redraw from a real-time thread — so the
    /// only thing crossing that boundary is one float behind a lock.
    private let latest = Latest()

    public init() {}

    // No deinit. It would be nonisolated and everything it needs to touch is main-actor
    // state, and there is nothing here that outlives the object anyway: `stop()` is called
    // from the Stop button and from the window's onDisappear, which app-ui.md requires —
    // "a microphone indicator left lit is worse than a missing feature".

    // MARK: - Control

    public func start() {
        guard !isRunning else { return }
        failure = nil
        // app-ui.md: request permission when the user starts a test, never at launch. A
        // permission prompt during onboarding, for a capability not yet in use, costs installs.
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.failure = "Micpeg needs permission to use the microphone. "
                                 + "Allow it in System Settings > Privacy & Security > Microphone."
                    return
                }
                self.reallyStart()
            }
        }
    }

    public func stop() {
        restart?.cancel()
        restart = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        isSilent = false
        quietSince = nil
        levels = [Float](repeating: 0, count: Self.slots)
    }

    // MARK: - Engine

    private func reallyStart() {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        // A device with no channels is not something to open — that is the shape a
        // disconnected default input leaves behind, and starting on it throws.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            failure = "This microphone isn't providing any audio channels right now."
            self.engine = nil
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [latest] buffer, _ in
            latest.store(Self.rms(of: buffer))
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Do nothing here. The header is explicit that tearing the engine down inside this
            // callback can deadlock, because it arrives on an internal dispatch queue.
            Task { @MainActor in self?.scheduleRestart() }
        }

        do {
            try engine.start()
        } catch {
            failure = "The microphone could not be opened: \(error.localizedDescription)"
            self.engine = nil
            return
        }

        isRunning = true
        quietSince = Date()
        // 30 Hz, and the redraw happens here rather than in the tap. app-ui.md: "never draw
        // from the tap callback".
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // .common so the meter keeps moving while a menu or a sheet is tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A device change moves the default input twice in quick succession — the daemon's 300 ms
    /// debounce and then its re-verify, roughly 400 ms apart. Restarting on the first one would
    /// tear the engine down again on the second, so this waits well past both.
    private func scheduleRestart() {
        restart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop()
                self.reallyStart()
            }
        }
        restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func sample() {
        let value = latest.load()
        levels.removeFirst()
        levels.append(value)

        // app-ui.md: after a few seconds below a silence threshold, name the likely causes.
        // One hardware mute switch otherwise reads as "micpeg is broken".
        //
        // The threshold is measured, not chosen. `MicpegApp meter` on this hardware:
        //
        //   Elgato Wave, quiet room     peak RMS 0.00218, mean 0.00170
        //   Elgato Wave, sound playing  peak RMS 0.00334
        //   built-in mic (lid closed)   peak RMS 0.00000, over 83 buffers
        //
        // The first draft used 0.01 and told a working microphone in a quiet room that no
        // sound was reaching it — the precise false alarm this hint exists to avoid. A room's
        // noise floor is thousandths; a device that is delivering nothing is exactly zero, and
        // that gap is what the threshold has to sit in.
        if value > Self.silenceThreshold {
            quietSince = nil
            isSilent = false
        } else if let since = quietSince {
            isSilent = Date().timeIntervalSince(since) > 3
        } else {
            quietSince = Date()
        }
    }

    /// Run the same tap outside SwiftUI and report what it measures.
    ///
    /// The meter is the one custom-drawn thing in the app, and a meter that never moves is
    /// indistinguishable from a microphone that is muted — which is exactly the confusion the
    /// silence hint exists to resolve. So the numbers behind it have to be checkable without
    /// a person watching a bar: `MicpegApp meter` prints them, from inside the app bundle so
    /// it runs under the app's own microphone permission.
    public nonisolated static func measure(seconds: Double,
                                           report: @escaping @Sendable (Float) -> Void,
                                           done: @escaping @Sendable (String?) -> Void) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            done("the default input reports \(format.channelCount) channels at"
                 + " \(format.sampleRate) Hz — nothing to open")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            report(rms(of: buffer))
        }
        do { try engine.start() } catch {
            done("engine.start() failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            input.removeTap(onBus: 0)
            engine.stop()
            done(nil)
        }
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        return (sum / Float(count)).squareRoot()
    }

    /// One float, written on the audio thread and read on the main actor.
    private final class Latest: @unchecked Sendable {
        private var value: Float = 0
        private let lock = NSLock()
        func store(_ new: Float) { lock.lock(); value = new; lock.unlock() }
        func load() -> Float { lock.lock(); defer { lock.unlock() }; return value }
    }
}
