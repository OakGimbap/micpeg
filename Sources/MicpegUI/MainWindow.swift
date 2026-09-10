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
    @State private var errorMessage: String?
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
            if let banner = model.banner {
                Section { BannerRow(banner: banner, act: onBannerAction) }
            }
            if let errorMessage {
                Section {
                    BannerRow(banner: .init(severity: .warning, title: errorMessage,
                                            body: "", actionTitle: nil, action: nil),
                              act: { _ in })
                }
            }

            switch model.body {
            case .unconfigured: unconfigured
            case .configured:   configured
            }
        }
        .formStyle(.grouped)
        // A Form on macOS is a scroll view, so with .windowResizability(.contentSize) the
        // window took a default height and scrolled its own content — measured: a 460x586
        // window with scrollbar arrows in the accessibility tree and the action buttons below
        // the fold, where VoiceOver could not reach their labels either. Disabling scrolling
        // lets the window size to the content, which is what app-ui.md asks for: "Fixed to its
        // content size; there is nothing to resize."
        .scrollDisabled(true)
        .frame(width: 460)
        .sheet(isPresented: $showingPicker) {
            DevicePicker(model: model) { device in
                errorMessage = model.pick(device)
            }
        }
        .onDisappear { test.stop() }
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
        } footer: {
            Text(Copy.deviceListFooter)
        }
        Section {
            Button(Copy.keepButton(pendingChoiceName)) {
                guard let device = pendingDevice else { return }
                errorMessage = model.pick(device)
                if errorMessage == nil { onFirstChoice() }
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
        model.inputs.first { $0.id == pendingChoice } ?? model.currentInput
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

        Section(Copy.activityTitle) {
            if model.activity.isEmpty {
                Text(Copy.activityEmpty).foregroundStyle(.secondary)
            } else {
                ForEach(model.activity.prefix(5)) { entry in
                    LabeledContent {
                        Text(entry.at, style: .relative)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Text(model.sentence(for: entry))
                    }
                }
            }
        }

        Section {
            HStack {
                Button(Copy.changeMicrophone) { showingPicker = true }
                Spacer()
                Button(model.isPaused ? Copy.resume : Copy.pause) {
                    errorMessage = model.setPaused(!model.isPaused)
                }
            }
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
                if !banner.body.isEmpty {
                    Text(banner.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                          || (selection == nil && device.id == model.currentInput?.id)
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
