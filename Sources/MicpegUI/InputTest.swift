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

// @preconcurrency: AVFAudio predates Sendable annotations, so AVAudioEngine is not Sendable
// and handing one to a dispatch queue — which is exactly what tearing the tap down after a
// timeout requires — warns. The engine is created, used and stopped without ever being touched
// from two places at once.
@preconcurrency import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
public final class InputTest {
    /// Roughly two seconds of history at 30 Hz.
    public static let slots = 64

    /// The bottom of the meter, in dBFS — and, because they are the same question, the line
    /// below which the window says nothing is arriving.
    ///
    /// They were two unrelated constants at first: a linear `0.0005` in the model and a
    /// `-60 dBFS` floor in the view, tuned separately, so the bar could sit visibly above the
    /// bottom while the text said no sound was reaching the microphone. One number, measured:
    ///
    ///   Elgato Wave, quiet room     RMS 0.00170-0.00334   ≈ -55 to -50 dBFS
    ///   built-in mic, lid closed    RMS 0.00000           = silence, no floor reaches it
    ///
    /// -66 dBFS sits below the quietest real room seen here and above nothing at all.
    public nonisolated static let floorDB: Float = -66

    /// RMS to a 0...1 bar height. `nonisolated` because the audio-side diagnostic
    /// (`MicpegApp meter`) reports in the same units the window draws in.
    public nonisolated static func level(fromRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(min(rms, 1))
        return min(1, max(0, (db - floorDB) / -floorDB))
    }

    public var isRunning: Bool { phase == .running }
    public private(set) var levels = [Float](repeating: 0, count: InputTest.slots)
    public private(set) var isSilent = false
    public private(set) var failure: String?
    /// Whether `failure` is the one the user can do something about. The other failures — no input
    /// channels, an engine that would not open — name a condition, and there is no pane to send
    /// anyone to; this one has a destination, and app-ui.md says a message with a destination
    /// should carry the button that goes there.
    public private(set) var failureIsPermission = false

    /// One variable for the lifecycle. It was three booleans — running, starting, and whether
    /// a stop had arrived while starting — kept in step by hand at five sites, and the double
    /// start `start()` describes lived in the combinations they allowed that meant nothing.
    private enum Phase { case idle, awaitingPermission, running }
    private var phase = Phase.idle

    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var quietSince: Date?

    /// A device change moves the default input more than once, and restarting on the first
    /// configuration change would tear the engine down again on the second. `DaemonTiming`
    /// holds the measurement.
    @ObservationIgnored
    private lazy var restart = Coalescer(delay: DaemonTiming.engineRestart) { [weak self] in
        guard let self, self.isRunning else { return }
        self.stop()
        self.reallyStart()
    }

    /// Written from the audio thread, read from the main actor. A tap callback must not touch
    /// observable state — SwiftUI would be asked to redraw from a real-time thread — so the
    /// only thing crossing that boundary is one float behind a lock.
    private let latest = Locked<Float>(0)

    public init() {}

    // No deinit. It would be nonisolated and everything it needs to touch is main-actor
    // state, and there is nothing here that outlives the object anyway: `stop()` is called
    // from the Stop button and from the window's onDisappear, which app-ui.md requires —
    // "a microphone indicator left lit is worse than a missing feature".

    // MARK: - Control

    public func start() {
        guard phase == .idle else { return }
        phase = .awaitingPermission
        failure = nil
        failureIsPermission = false
        // app-ui.md: request permission when the user starts a test, never at launch. A
        // permission prompt during onboarding, for a capability not yet in use, costs installs.
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                // Only a request still awaited may start an engine. A stop() while the TCC
                // prompt is up returns the phase to idle, and a press after that makes a second
                // request whose callback also lands here — after the first has started an
                // engine. Starting again would overwrite the engine, the observer and the timer
                // with no teardown, and stop() could then only ever reach the second: the first
                // engine would keep its tap installed with the microphone indicator lit and no
                // control left to turn it off.
                guard let self, self.phase == .awaitingPermission else { return }
                guard granted else {
                    self.phase = .idle
                    self.failure = Copy.microphonePermissionDenied
                    self.failureIsPermission = true
                    return
                }
                self.reallyStart()
            }
        }
    }

    public func stop() {
        phase = .idle
        restart.cancel()
        timer?.invalidate()
        timer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isSilent = false
        quietSince = nil
        levels = [Float](repeating: 0, count: Self.slots)
    }

    // MARK: - Engine

    private func reallyStart() {
        // Idempotent by construction rather than by the callers being careful. Anything that
        // reaches here with an engine already running tears it down first.
        if engine != nil { stop() }
        switch Self.openTap(onBuffer: { [latest] buffer in
            latest.set(Self.level(fromRMS: Self.rms(of: buffer)))
        }) {
        case .failure(let error):
            phase = .idle
            failure = error.message
            return
        case .success(let engine):
            self.engine = engine
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // Do nothing here. The header is explicit that tearing the engine down inside
                // this callback can deadlock, because it arrives on an internal dispatch queue.
                //
                // The task's own capture list copies the weak reference. Naming the outer `self`
                // inside the task instead reads a captured `var` from concurrently executing
                // code, which Swift 5.10 rejects — CI's toolchain; the local one did not.
                Task { @MainActor [weak self] in self?.restart.schedule() }
            }
        }

        phase = .running
        quietSince = Date()
        // 30 Hz, and the redraw happens here rather than in the tap. app-ui.md: "never draw
        // from the tap callback".
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // The timer is on the main runloop and this type is @MainActor, so there is
            // nothing to hop to — a Task here allocated one per frame and deferred the sample
            // by a runloop turn for nothing.
            MainActor.assumeIsolated { self?.sample() }
        }
        // .common so the meter keeps moving while a menu or a sheet is tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let value = latest.get()
        // One write to the observable array per frame. `removeFirst` + `append` went through
        // the observation registrar twice and memmoved the buffer each time.
        var next = levels
        next.removeFirst()
        next.append(value)
        levels = next

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
        if value > 0 {
            quietSince = nil
            isSilent = false
        } else if let since = quietSince {
            isSilent = Date().timeIntervalSince(since) > 3
        } else {
            quietSince = Date()
        }
    }

    /// Why the microphone could not be opened, already in the user's words — every caller
    /// shows this rather than inspecting it.
    public struct TapFailure: Error, Sendable {
        public let message: String
    }

    /// Open the default input and deliver every buffer to `onBuffer`, or say why not.
    ///
    /// One place, because there are two callers — the window's meter and `MicpegApp meter` —
    /// and the diagnostic is only worth anything if it exercises the same path the window
    /// does. Written twice, "the same tap" was a comment rather than a fact, and the three
    /// rules the file header quotes from AVFAudio's headers (remove the tap before installing,
    /// guard the channel count, never tear down inside the notification handler) had to be
    /// remembered separately in each copy.
    public nonisolated static func openTap(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> Result<AVAudioEngine, TapFailure> {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A device with no channels is not something to open — that is the shape a
        // disconnected default input leaves behind, and starting on it throws.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            return .failure(TapFailure(message: Copy.microphoneNoChannels))
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        do { try engine.start() } catch {
            return .failure(TapFailure(
                message: Copy.microphoneCouldNotOpen(error.localizedDescription)))
        }
        return .success(engine)
    }

    /// Run the same tap outside SwiftUI and report the raw RMS of every buffer.
    ///
    /// The meter is the one custom-drawn thing in the app, and a meter that never moves is
    /// indistinguishable from a microphone that is muted — which is exactly the confusion the
    /// silence hint exists to resolve. So the numbers behind it have to be checkable without
    /// a person watching a bar: `MicpegApp meter` prints them, from inside the app bundle so
    /// it runs under the app's own microphone permission.
    public nonisolated static func measure(seconds: Double,
                                           report: @escaping @Sendable (Float) -> Void,
                                           done: @escaping @Sendable (String?) -> Void) {
        switch openTap(onBuffer: { report(rms(of: $0)) }) {
        case .failure(let error):
            done(error.message)
        case .success(let engine):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                done(nil)
            }
        }
    }

    /// `nonisolated`: this runs on the audio render thread, which is the whole reason the
    /// result crosses to the main actor through a lock rather than being touched here.
    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        return (sum / Float(count)).squareRoot()
    }
}
