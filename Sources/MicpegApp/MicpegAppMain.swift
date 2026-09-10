// The app: @main, the delegate, and the wiring between the window and the background agent.
//
// Thin on purpose. The window and everything it renders live in MicpegUI, which knows nothing
// about ServiceManagement — deciding whether the agent is healthy needs SMAppService, the
// legacy plist, launchd and proc_pidpath, and all of that is registration work. This file is
// where the two meet: it takes InstallSurvey's verdict, reduces it to the one thing the window
// needs to say, and turns the window's banner buttons back into registration operations.

import AppKit
import MicpegUI
import ServiceManagement
import SwiftUI

@main
struct MicpegSettingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var agent = AgentController()
    @State private var model = AppModel()

    init() {
        // Exits the process if an argument was given. See Headless.swift.
        Headless.runIfRequested()
    }

    var body: some Scene {
        WindowGroup(Copy.appName) {
            MainWindow(model: model,
                       onBannerAction: handle(_:),
                       onFirstChoice: enableAfterFirstChoice)
                .task {
                    model.startWatching()
                    await reconcile()
                }
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Agent ↔ window

    /// Run at launch. Surveys the machine, repairs the one condition that can be repaired
    /// without asking, and tells the window what is true.
    ///
    /// **Only `.moved` is repaired automatically, and only when a registration already
    /// exists.** That verdict comes from the path this app recorded when it registered, so it
    /// is not an inference — the app is not where it registered from, and nothing else will
    /// notice. `.stale` is deliberately *not* repaired: a job that has run in the last minute
    /// sits at "spawn scheduled" because of ThrottleInterval 60, which is indistinguishable at
    /// this moment from a job that will never spawn again, and tearing down a healthy
    /// registration is worse than showing a button. And with no record at all nothing is
    /// registered automatically: the first registration adds a login item, which is the user's
    /// decision to make in onboarding.
    @MainActor
    private func reconcile() async {
        let survey = InstallSurvey.take()
        if case .moved(let from) = survey.verdict {
            let outcome = await Task.detached { Migration.repair() }.value
            agent.absorb(outcome, label: "auto-repair after a move")
            model.setAgent(outcome.ok ? .repairedAfterMove(from: from)
                                      : condition(for: outcome.survey))
        } else {
            model.setAgent(condition(for: survey))
        }
        model.reloadAll()
    }

    @MainActor
    private func condition(for survey: InstallSurvey) -> AppModel.AgentCondition {
        switch survey.verdict {
        case .healthy:          return .healthy
        case .requiresApproval: return .needsApproval
        case .legacyPresent:    return .legacyPresent
        case .notRegistered:    return .notRegistered
        // Both mean "nothing from this bundle is running the label right now", which is the
        // same sentence to the user and the same repair.
        case .stale, .foreignBundle, .moved:
            return .notRunning
        }
    }

    @MainActor
    private func handle(_ action: AppModel.Banner.Action) {
        switch action {
        case .openLoginItems:
            agent.openLoginItems()
        case .repairAgent:
            run { Migration.repair() }
        case .migrateLegacy:
            run { Migration.migrate() }
        }
    }

    /// The first "Keep <device>" writes the config through the CLI. That alone leaves a
    /// configured machine with no daemon, so this is where the login item is actually created —
    /// after the user has made a deliberate choice, never at launch.
    @MainActor
    private func enableAfterFirstChoice() {
        run { Migration.migrate() }
    }

    @MainActor
    private func run(_ body: @escaping @Sendable () -> Migration.Outcome) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { body() }.value
            agent.absorb(outcome, label: "window action")
            model.setAgent(condition(for: outcome.survey))
            model.reloadAll()
        }
    }
}

/// docs/app-design.md, "Process model": quitting the app must never look like it stops the
/// feature, and there is nothing for the GUI to do once its window is gone. launchd holds the
/// daemon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
