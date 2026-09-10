// Stages 2 and 3 of the build order in docs/app-design.md: the smallest app that can answer
// the questions that document lists as documented-but-unobserved — does BundleProgram
// resolve, does registration survive a move and an update, is .requiresApproval reachable and
// recoverable, does deleting the app tear the agent down — and then the smallest app that can
// take over from the hand-written LaunchAgent and repair a registration that has come loose
// from this bundle.
//
// This is not the interface. docs/app-ui.md governs that, and it lands at stage 4. What
// this window owes the person testing it is the opposite of a finished design: every
// SMAppService result verbatim, including the error domain and code, and a status read
// taken *after* each call rather than inferred from it. The file is expected to be deleted
// and replaced, not grown into the real thing.

import AppKit
import ServiceManagement
import SwiftUI

@main
struct MicpegSettingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var agent = AgentController()

    init() {
        // Exits the process if an argument was given. See Headless.swift for why the
        // harness has a terminal front end at all.
        Headless.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Micpeg") {
            HarnessView(agent: agent)
        }
        .windowResizability(.contentSize)
    }
}

/// docs/app-design.md, "Process model": quitting the app must never look like it stops the
/// feature, and there is nothing for the GUI to do once its window is gone. launchd holds
/// the daemon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct HarnessView: View {
    let agent: AgentController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stage 2–3 harness — not the shipping interface")
                .font(.headline)
            Text("Registers, migrates and repairs the background agent, and shows exactly "
                 + "what ServiceManagement and launchd reported. Nothing here is designed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Two readings, deliberately side by side. SMAppService answers for whatever
            // holds the label; the verdict answers for this bundle. Stage 2 measured them
            // disagreeing — `.enabled`, about somebody else's agent.
            LabeledContent("Status") {
                Text(AgentController.describe(agent.status))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(agent.status == .enabled ? .primary : .secondary)
            }
            LabeledContent("Verdict") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.survey.verdictName)
                        .font(.system(.body, design: .monospaced))
                    Text(agent.survey.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Running from") {
                Text(agent.survey.job.runningExecutable?.path ?? "nothing is running")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            LabeledContent("Legacy plist") {
                Text(agent.survey.legacyPlistExists ? "PRESENT — must be torn down first"
                                                    : "absent")
                    .font(.system(.caption, design: .monospaced))
            }
            LabeledContent("Registered from") {
                Text(agent.survey.registeredFrom?.bundlePath ?? "no record")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(agent.survey.hasMoved ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            LabeledContent("CLI on PATH") {
                Text(agent.survey.cli.description)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Plist") {
                Text(AgentController.plistName)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Bundle") {
                Text(Bundle.main.bundleURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            // Stage 3. Survey changes nothing; Link CLI is the "after asking" in
            // docs/app-design.md's migration flow, which is why it is a button and never
            // something the app does on its own.
            HStack {
                Button("Survey") { agent.takeSurvey() }
                Button("Migrate") { agent.migrate() }
                Button("Repair") { agent.repair() }
                Button("Link CLI…") { agent.linkCLI() }
                if agent.busy { ProgressView().controlSize(.small) }
            }
            .disabled(agent.busy)

            // Stage 2. Raw SMAppService, nothing interpreted.
            HStack {
                Button("Register") { agent.register() }
                Button("Unregister") { agent.unregister() }
                Button("Re-register") { agent.reregister() }
                Button("Refresh") { agent.refresh() }
            }
            .disabled(agent.busy)
            HStack {
                Button("Open Login Items…") { agent.openLoginItems() }
                Spacer()
                Button("Copy transcript") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(agent.copyTranscript(), forType: .string)
                }
            }

            Divider()

            Text("Transcript")
                .font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(agent.transcript) { entry in
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(4)
            }
            .frame(height: 220)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .frame(width: 680)
    }
}
