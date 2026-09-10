// Stage 2 of the build order in docs/app-design.md: the smallest app that can answer the
// questions that document lists as documented-but-unobserved — does BundleProgram resolve,
// does registration survive a move and an update, is .requiresApproval reachable and
// recoverable, does deleting the app tear the agent down.
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
            Text("Stage 2 harness — not the shipping interface")
                .font(.headline)
            Text("Registers and unregisters the background agent, and shows exactly what "
                 + "ServiceManagement reported. Nothing here is designed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("Status") {
                Text(AgentController.describe(agent.status))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(agent.status == .enabled ? .primary : .secondary)
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

            HStack {
                Button("Register") { agent.register() }
                Button("Unregister") { agent.unregister() }
                Button("Re-register") { agent.reregister() }
                Button("Refresh") { agent.refresh() }
            }
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
            .frame(height: 180)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .frame(width: 620)
    }
}
