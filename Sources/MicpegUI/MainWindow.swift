// The window.
//
// app-ui.md's governing idea: micpeg does the job System Settings → Sound should have done, so
// matching that pane's visual language is the correct answer to "where does this belong", not
// imitation. On macOS that means `Form` + `.formStyle(.grouped)` with `LabeledContent` rows —
// the native feel comes from choosing the right container, not from styling one.
//
// Nothing here sets a margin or an inter-row spacing. app-ui.md: "Let `Form` supply the inner
// rhythm; do not add manual padding between its rows." That instruction is doing real work in
// this project — Apple's current HIG pages are JavaScript-rendered and could not be fetched, so
// hand-chosen numbers here would be recollection, and recollection is what this codebase does
// not build on. Delegating the numbers to the standard container is how that is avoided.
//
// The skeleton is constant and only the banner and the body change:
//
//     banner    absent when healthy
//     body      the device list when unconfigured, Output/Input rows when configured
//     meter     level + test control
//     actions   Change Microphone · Pause
//
// There is no activity list here any more. It was an "Earlier" disclosure, the only thing in
// this window able to change its height, and this window is sized to its content — so opening
// it resized the whole window. It is its own window now (ActivityWindow.swift), and the one
// thing from it that has to interrupt, a restore that failed, is a banner.

import CoreAudio
import SwiftUI

/// `@MainActor`, like every view in this target. The macOS 15 SDK declares `View` itself
/// main-actor isolated, so with Xcode 16 and later the mark changes nothing. The macOS 14 SDK
/// isolates only `body`, and CI's macos-14 runner (Swift 5.10) rejected every computed property
/// and helper here that reads `AppModel` or `InputTest` — the first time settings-app reached
/// CI, after the local toolchain had compiled all of it without a warning.
@MainActor
public struct MainWindow: View {
    /// The main window's scene. MicpegAppMain.swift declares it as a single `Window` and says
    /// why it is not a `WindowGroup`.
    public static let sceneID = "main"

    private let model: AppModel
    private let onBannerAction: (AppModel.Banner.Action) -> Void
    /// Called after the user chooses a microphone for the first time. Choosing writes the
    /// config through the CLI, which is not enough on its own — with no agent registered there
    /// is no daemon to read it. Registering is the app target's job, so the window asks.
    private let onFirstChoice: () -> Void

    @State private var showingPicker = false
    @State private var errorMessage: String?
    @Environment(\.openWindow) private var openWindow
    /// Built on every init of this struct and discarded after the first, like any `@State`
    /// default — `State(wrappedValue:)` written out in `init` is no lazier, which is what this
    /// used to be on the theory that it was. Cheap: no engine exists until `start()`.
    @State private var test = InputTest()

    public init(model: AppModel,
                onBannerAction: @escaping (AppModel.Banner.Action) -> Void,
                onFirstChoice: @escaping () -> Void = {}) {
        self.model = model
        self.onBannerAction = onBannerAction
        self.onFirstChoice = onFirstChoice
    }

    public var body: some View {
        Form {
            // Before everything, and instead of everything. Nothing in `running` can be acted on
            // from a disk image: choosing a microphone would write a config for a helper this
            // copy can never register. app-ui.md, "One window, several states" — a state rather
            // than an alert, because an alert is dismissible and a dismissed alert leaves the
            // user pressing Keep from the same place.
            if model.cannotRunHere {
                cannotRunHere
            } else {
                running
            }
        }
        .formStyle(.grouped)
        .confirmsBlockedChoice($blockedChoice, keep: keepFirst)
        // Scrolling off — and it is `.fixedSize` below that sizes the window, not this.
        // `.scrollDisabled(true)` was first tried on its own, on the theory that a Form would
        // then size the window to its content; measured, it does not — the window stays at the
        // same 460x586 and the content past the bottom edge is simply cut off. The action
        // buttons were still in the accessibility tree, which is how the first pass missed it,
        // and not on screen, which is what a screenshot showed (verification.md §22).
        //
        // With `.fixedSize` doing the sizing, the scroll view had nothing to scroll to and
        // scrolled anyway: the content was a fraction of a point taller than the window it
        // sized, so the scroll bar had a point of travel. Disabled, the scroll bar is gone and
        // the window still follows its content as the test hint comes and goes
        // (verification.md §25). The cost is that content taller than the screen would be cut
        // off rather than scroll; the longest state is the unconfigured list, a row per
        // microphone. `.windowResizability(.contentSize)` still means there is nothing to resize.
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingPicker) {
            DevicePicker(model: model) { device in
                Task { errorMessage = await model.pick(device) }
            }
        }
        // The meter and its Stop Test button exist only in the configured rows, which an
        // unreadable settings file still shows. If the settings file is removed while a test is
        // running the branch disappears without `onDisappear` firing, leaving the microphone
        // open and no control to close it.
        .onChange(of: model.body) { _, body in
            if body == .unconfigured { test.stop() }
        }
        .onDisappear { test.stop() }
    }

    /// `.showActivity` opens a window, which takes this view's environment; the rest are
    /// registration work and belong to the app target.
    private func handle(_ action: AppModel.Banner.Action) {
        if action == .showActivity {
            openWindow(id: ActivityWindow.sceneID)
        } else {
            onBannerAction(action)
        }
    }

    /// Everything the window says when it is installed somewhere it can work from.
    @ViewBuilder
    private var running: some View {
        if let banner = model.banner {
            Section { BannerRow(banner: banner, act: handle) }
        }
        if let errorMessage {
            // Not a Banner. Assembling one with an empty body and a no-op action, purely
            // to reuse BannerRow, is what put an `if !body.isEmpty` branch inside
            // BannerRow and made every reader check whether a button could appear here.
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }

        // Nothing until the files and devices have been read once: `model.body` starts at
        // unconfigured, and the first frame used to be onboarding for someone who had chosen
        // a microphone long before.
        if model.hasLoaded {
            switch model.body {
            case .unconfigured: unconfigured
            // Same body: the rows and the meter describe the machine as it is, which is true
            // whatever the file says. The banner says what is wrong with the file.
            case .configured, .settingsUnreadable: configured
            }
        }
    }

    // MARK: - Can't run from here

    @ViewBuilder
    private var cannotRunHere: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.cannotRunHereTitle).fontWeight(.medium)
                    Text(Copy.cannotRunHereBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "arrow.down.app")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Unconfigured

    @ViewBuilder
    private var unconfigured: some View {
        Section {
            Text(Copy.onboardingHeadline)
            Text(Copy.onboardingInstruction)
                .foregroundStyle(.secondary)
            Text(Copy.onboardingPromise)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            // Up to `longInputList` devices this is exactly the section verification.md §25
            // measured: plain Form rows, the window sized to them by `.fixedSize` below.
            //
            // Past it the list scrolls inside a cap, because `.scrollDisabled(true)` plus
            // `.fixedSize` means the window follows its content until the content is taller than
            // the screen, and then the content is *clipped* rather than scrolled. The row that
            // goes off the bottom is the Keep button — and §22 measured that a button off the
            // bottom edge is still in the accessibility tree, so nothing automated notices. Ten
            // inputs is not exotic: an aggregate device, a multi-channel interface, Continuity
            // Mic and a webcam get there.
            //
            // A `List` rather than a `ScrollView` because DevicePicker below already scrolls
            // these same rows that way.
            if model.inputs.count > longInputList {
                List { DeviceList(model: model, selection: $pendingChoice) }
                    .listStyle(.inset)
                    .frame(height: longInputListHeight)
            } else {
                DeviceList(model: model, selection: $pendingChoice)
            }
        } footer: {
            Text(Copy.deviceListFooter)
        }
        // Seed the selection once rather than teaching the list a second rule about what nil
        // means. The sheet's Done button reads nil as "nothing chosen" and disables itself; a
        // list that also drew the current input as selected while the binding was nil made the
        // two disagree.
        //
        // On the Section rather than on the list, so it survives the branch above.
        //
        // Seeded from `suggestedChoice`, not the current input: on a fresh install that is often
        // the headset macOS has just moved it to.
        .task { pendingChoice = pendingChoice ?? model.suggestedChoice?.uid }
        Section {
            Button(keepButtonTitle) {
                guard let device = pendingDevice else { return }
                if model.isBlocked(device) {
                    blockedChoice = device
                } else {
                    keepFirst(device)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pendingDevice == nil)
        } footer: {
            // Pre-announcing the system's own notification. Without this, "a login item was
            // added" reads as something installing itself behind the user's back.
            Text(Copy.backgroundHelperNote)
        }
    }

    /// Where the unconfigured list stops growing the window and starts scrolling. Not measured —
    /// verification.md §25 measured the configured window and said so. Six is chosen to leave the
    /// common case untouched; §29 is where the long case gets looked at on a real screen.
    private let longInputList = 6
    private let longInputListHeight: CGFloat = 200

    @State private var pendingChoice: String?
    @State private var blockedChoice: AudioDevice?

    private var pendingDevice: AudioDevice? {
        model.inputs.first { $0.uid != nil && $0.uid == pendingChoice }
    }
    /// "Keep None" is not a sentence anyone means. See Copy.keepButtonNoChoice.
    private var keepButtonTitle: String {
        pendingDevice.map { Copy.keepButton($0.name) } ?? Copy.keepButtonNoChoice
    }

    /// The first choice, written through the CLI; then the app target is asked to register the
    /// agent that will keep it.
    private func keepFirst(_ device: AudioDevice) {
        Task {
            errorMessage = await model.pick(device)
            if errorMessage == nil { onFirstChoice() }
        }
    }

    // MARK: - Configured

    @ViewBuilder
    private var configured: some View {
        Section {
            LabeledContent(Copy.outputLabel) {
                Text(model.currentOutput?.name ?? Copy.noDevice)
            }
            LabeledContent(Copy.inputLabel) {
                HStack(spacing: 6) {
                    Text(model.currentInput?.name ?? Copy.noDevice)
                    if model.daemon?.kind == .pinned, model.inputIsTarget, !model.isPaused {
                        // Color is never the only signal: the summary sentence below says the
                        // same thing in words. `inputIsTarget`, not the daemon's state alone: a
                        // failed revert leaves that at PINNED with another device selected.
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
            }
        } footer: {
            Text(model.summary)
        }

        Section {
            LevelMeter(test: test)
            Button(test.isRunning ? Copy.stopTest : Copy.startTest) {
                test.isRunning ? test.stop() : test.start()
            }
            // Only for the failure that has somewhere to go. A row rather than something in the
            // footer below, because a footer is explanation and this is an action — and the
            // needs-approval banner has taken the user to Login Items with a button since
            // stage 3, while this message named a pane and left them to find it.
            if test.failureIsPermission {
                Button(Copy.openMicrophoneSettings) {
                    SystemSettings.openMicrophonePrivacy()
                }
            }
        } footer: {
            if test.isRunning, test.isSilent {
                // Verbatim: both halves are already translated, and a literal here would be a
                // LocalizedStringKey, "%@ %@", looked up in the table and never found.
                Text(verbatim: "\(Copy.silenceWarning) \(model.silenceHint)")
            } else if test.isRunning {
                Text(Copy.testHint)
            } else if let failure = test.failure {
                Text(failure)
            }
        }

        Section {
            HStack {
                Button(Copy.changeMicrophone) { showingPicker = true }
                Spacer()
                Button(model.isPaused ? Copy.resume : Copy.pause) {
                    Task { errorMessage = await model.setPaused(!model.isPaused) }
                }
            }
        }
    }

}

// MARK: - Pieces

@MainActor
struct BannerRow: View {
    let banner: AppModel.Banner
    let act: (AppModel.Banner.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).fontWeight(.medium)
                Text(banner.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = banner.action {
                Button(action.title) { act(action) }
            }
        }
    }

    // app-ui.md: red exclusively for BACKOFF and approval failure.
    private var tint: Color {
        switch banner.severity {
        case .informational: return .secondary
        case .warning:       return .orange
        case .failure:       return .red
        }
    }
    private var symbol: String {
        switch banner.severity {
        case .informational: return "info.circle"
        case .warning:       return "exclamationmark.triangle"
        case .failure:       return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
struct DeviceList: View {
    let model: AppModel
    /// A UID, not an `AudioDeviceID`. IDs are reused across reconnects (CLAUDE.md, principle 3),
    /// so a device replugged while the list was open came back under a new one and the selection
    /// pointed at nothing — the sheet's Done then closed without keeping anything. A device with
    /// no UID cannot be pinned, so it cannot be selected either.
    @Binding var selection: String?

    private func isSelected(_ device: AudioDevice) -> Bool {
        device.uid != nil && device.uid == selection
    }

    var body: some View {
        ForEach(model.inputs) { device in
            Button {
                selection = device.uid
            } label: {
                HStack {
                    Image(systemName: isSelected(device)
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(device.name)
                    Spacer()
                    if model.isBlocked(device) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(Copy.blockedDeviceWarning(device.name))
                            .accessibilityLabel(Copy.blockedDeviceWarning(device.name))
                    }
                    Text(device.transport)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(device.uid == nil)
            .accessibilityAddTraits(isSelected(device) ? [.isSelected] : [])
        }
    }
}

@MainActor
struct DevicePicker: View {
    let model: AppModel
    let onChoose: (AudioDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var blockedChoice: AudioDevice?

    /// Looked up by UID on every draw, so a device replugged while the sheet is open is found
    /// under its new ID, and Done is disabled while the chosen one is not connected. It used to
    /// match the ID the sheet opened with, find nothing after a replug, and close without
    /// keeping anything.
    private var selectedDevice: AudioDevice? {
        model.inputs.first { $0.uid != nil && $0.uid == selection }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(Copy.onboardingInstruction).font(.headline)
            List {
                DeviceList(model: model, selection: $selection)
            }
            .listStyle(.inset)
            .frame(height: 180)
            // Open on whatever is kept right now. Without this the sheet showed two empty
            // radio buttons and the user could not tell which microphone they already had —
            // and Done stayed disabled until they picked one, so "change my mind" meant
            // Cancel rather than seeing the current choice and leaving it alone.
            .task { selection = selection ?? model.pinnedDevice?.uid ?? model.suggestedChoice?.uid }
            Text(Copy.deviceListFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Copy.cancel) { dismiss() }
                Button(Copy.done) {
                    guard let device = selectedDevice else { return }
                    if model.isBlocked(device) {
                        blockedChoice = device
                    } else {
                        choose(device)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDevice == nil)
            }
        }
        .padding()
        .frame(width: 380)
        .confirmsBlockedChoice($blockedChoice, keep: choose)
    }

    private func choose(_ device: AudioDevice) {
        onChoose(device)
        dismiss()
    }
}

extension View {
    /// app-ui.md, Unconfigured: pinning a device on a blocked transport "produces an agent that
    /// can never act … Match that behavior: warn and confirm, do not silently disable." Both
    /// places a microphone is chosen ask here, once, before keeping one. Neither did: onboarding
    /// showed a ⚠ only where a settings file already existed, and the CLI's own warning was
    /// dropped because `pick` succeeds.
    @MainActor
    fileprivate func confirmsBlockedChoice(_ device: Binding<AudioDevice?>,
                                           keep: @escaping (AudioDevice) -> Void) -> some View {
        confirmationDialog(
            device.wrappedValue.map { Copy.keepBlockedTitle($0.name) } ?? "",
            isPresented: Binding(get: { device.wrappedValue != nil },
                                 set: { if !$0 { device.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: device.wrappedValue
        ) { chosen in
            Button(Copy.keepAnyway) { keep(chosen) }
            Button(Copy.cancel, role: .cancel) {}
        } message: { chosen in
            Text(Copy.blockedDeviceWarning(chosen.name))
        }
    }
}

// MARK: - Previews

#Preview("Active") {
    MainWindow(model: .preview(), onBannerAction: { _ in })
}

#Preview("Unconfigured") {
    MainWindow(model: .preview(config: .ok(.init(enabled: true, priority: [],
                                                 blockedTransports: ["bluetooth"]))),
               onBannerAction: { _ in })
}

#Preview("Needs approval") {
    MainWindow(model: .preview(agent: .needsApproval), onBannerAction: { _ in })
}

#Preview("Restore failed") {
    MainWindow(model: .preview(currentInputUID: "uid-pods",
                               activity: [Activity(at: Date(), kind: .problem(.restoreFailed),
                                                   raw: "REVERT FAILED")]),
               onBannerAction: { _ in })
}
