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
//     activity  the most recent daemon actions
//     actions   Change Microphone · Pause

import CoreAudio
import SwiftUI

public struct MainWindow: View {
    @Bindable private var model: AppModel
    private let onBannerAction: (AppModel.Banner.Action) -> Void
    /// Called after the user chooses a microphone for the first time. Choosing writes the
    /// config through the CLI, which is not enough on its own — with no agent registered there
    /// is no daemon to read it. Registering is the app target's job, so the window asks.
    private let onFirstChoice: () -> Void

    @State private var showingPicker = false
    @State private var showEarlier = false
    @State private var errorMessage: String?
    @State private var test: InputTest

    public init(model: AppModel,
                onBannerAction: @escaping (AppModel.Banner.Action) -> Void,
                onFirstChoice: @escaping () -> Void = {}) {
        self.model = model
        self.onBannerAction = onBannerAction
        self.onFirstChoice = onFirstChoice
        // Not a default value on the property: that expression is evaluated on every struct
        // init, allocating an InputTest that SwiftUI immediately discards.
        _test = State(wrappedValue: InputTest())
    }

    public var body: some View {
        Form {
            if let banner = model.banner {
                Section { BannerRow(banner: banner, act: onBannerAction) }
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

            switch model.body {
            case .unconfigured: unconfigured
            // Same body: the daemon is still enforcing the settings it loaded last, so the
            // rows and the meter are all true. The banner says what is wrong with the file.
            case .configured, .settingsUnreadable: configured
            }
        }
        .formStyle(.grouped)
        // Deliberately *not* .scrollDisabled(true). That was tried, on the theory that a Form
        // would then size the window to its content; measured, it does not — the window stays
        // at the same 460x586 and the content past the bottom edge is simply cut off. The
        // action buttons were still in the accessibility tree, which is how the first pass
        // missed it, and not on screen, which is what a screenshot showed. Scrolling is the
        // safety net; keeping the content short enough not to need it is the design, and
        // `.windowResizability(.contentSize)` still means there is nothing to resize.
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingPicker) {
            DevicePicker(model: model) { device in
                Task { errorMessage = await model.pick(device) }
            }
        }
        // The meter and its Stop Test button exist only in the configured body. If the
        // settings file is removed while a test is running the branch disappears without
        // `onDisappear` firing, leaving the microphone open and no control to close it.
        .onChange(of: model.body) { _, body in
            if body != .configured { test.stop() }
        }
        .onDisappear {
            test.stop()
            // Releases the directory descriptor, its dispatch source and three HAL listeners.
            // They used to stay installed for the life of the process.
            model.stopWatching()
        }
    }

    // MARK: - Unconfigured

    @ViewBuilder
    private var unconfigured: some View {
        Section {
            Text(Copy.onboardingHeadline)
            Text(Copy.onboardingInstruction)
                .foregroundStyle(.secondary)
        }
        Section {
            DeviceList(model: model, selection: $pendingChoice)
                // Seed the selection once rather than teaching the list a second rule about
                // what nil means. The sheet's Done button reads nil as "nothing chosen" and
                // disables itself; a list that also drew the current input as selected while
                // the binding was nil made the two disagree.
                .task { pendingChoice = pendingChoice ?? model.currentInput?.id }
        } footer: {
            Text(Copy.deviceListFooter)
        }
        Section {
            Button(Copy.keepButton(pendingChoiceName)) {
                guard let device = pendingDevice else { return }
                Task {
                    errorMessage = await model.pick(device)
                    if errorMessage == nil { onFirstChoice() }
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

    @State private var pendingChoice: AudioDeviceID?

    private var pendingDevice: AudioDevice? {
        model.inputs.first { $0.id == pendingChoice }
    }
    private var pendingChoiceName: String { pendingDevice?.name ?? Copy.noDevice }

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
                    if model.daemon?.kind == .pinned, model.targetIsConnected, !model.isPaused {
                        // Color is never the only signal: the summary sentence below says the
                        // same thing in words.
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
        } footer: {
            if test.isRunning, test.isSilent {
                Text("\(Copy.silenceWarning) \(model.silenceHint)")
            } else if test.isRunning {
                Text(Copy.testHint)
            } else if let failure = test.failure {
                Text(failure)
            }
        }

        // app-ui.md's skeleton: "activity — most recent daemon action, expandable". One row.
        // Rendering five was a misreading of that line and it had a visible cost: the section
        // grew tall enough to push the only two controls in the window off the bottom edge.
        Section(Copy.activityTitle) {
            if let latest = model.activity.first {
                activityRow(latest)
                if model.activity.count > 1 {
                    // An explicit binding rather than DisclosureGroup's own state: it is the
                    // one thing in this window that changes its height, so whether it is open
                    // has to be inspectable to test that the window grows instead of clipping.
                    DisclosureGroup(Copy.activityEarlier, isExpanded: $showEarlier) {
                        ForEach(model.activity.dropFirst().prefix(9)) { activityRow($0) }
                    }
                }
            } else {
                Text(Copy.activityEmpty).foregroundStyle(.secondary)
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

    private func activityRow(_ entry: Activity) -> some View {
        LabeledContent {
            Text(entry.at, style: .relative)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } label: {
            Text(model.sentence(for: entry))
        }
    }
}

// MARK: - Pieces

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
            if let title = banner.actionTitle, let action = banner.action {
                Button(title) { act(action) }
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

struct DeviceList: View {
    @Bindable var model: AppModel
    @Binding var selection: AudioDeviceID?

    var body: some View {
        ForEach(model.inputs) { device in
            Button {
                selection = device.id
            } label: {
                HStack {
                    Image(systemName: selection == device.id
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
            .accessibilityAddTraits(selection == device.id ? [.isSelected] : [])
        }
    }
}

struct DevicePicker: View {
    @Bindable var model: AppModel
    let onChoose: (AudioDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AudioDeviceID?

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
            .task { selection = selection ?? model.pinnedDevice?.id ?? model.currentInput?.id }
            Text(Copy.deviceListFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Copy.cancel) { dismiss() }
                Button(Copy.done) {
                    if let device = model.inputs.first(where: { $0.id == selection }) {
                        onChoose(device)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding()
        .frame(width: 380)
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
