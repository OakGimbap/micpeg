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
                // Both windows start and stop watching side by side, through the pair SwiftUI
                // guarantees to match. The model counts watchers, and a stop without its start
                // would take them out from under whichever window is left.
                .onAppear { model.startWatching() }
                .onDisappear { model.stopWatching() }
                .task { await reconcile() }
        }
        .windowResizability(.contentSize)

        // After the WindowGroup, so the group stays the scene that opens at launch. A singleton
        // `Window` is listed in the Window menu by SwiftUI itself (Apple's `Window`
        // documentation), so there is no CommandGroup for it.
        //
        // Sized by the user, not by its content: a list that grows as events arrive must never
        // drag its window's frame along, which is what the main window's `.contentSize` did to
        // the disclosure this replaces.
        Window(Copy.activityWindowTitle, id: ActivityWindow.sceneID) {
            ActivityWindow(model: model)
                // Here rather than in the view, so a preview of the view attaches nothing. And
                // its own, not borrowed from the main window: this window can be restored at
                // launch on its own (`restorationBehavior`, which could say otherwise, is
                // macOS 15 only), and the model counts watchers, so both holding them is fine.
                .onAppear {
                    model.startWatching()
                    model.reloadAll()
                }
                .onDisappear { model.stopWatching() }
        }
        // Wider than the main window: at 460 a row naming two devices truncated the first
        // ("MacBook P…Microphone") beside a clock time, seen in the first screenshot.
        .defaultSize(width: 560, height: 600)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("l", modifiers: [.command, .option])
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
        // Off the main actor: this forks `launchctl print` and waits for it, then makes two
        // synchronous ServiceManagement round trips to backgroundtaskmanagementd. On the main
        // thread that is the window's first frame blocked for as long as btmd takes.
        let survey = await Task.detached { InstallSurvey.take() }.value
        if case .moved(let from) = survey.verdict {
            let outcome = await Task.detached { Migration.repair() }.value
            AgentController.report(outcome, label: "auto-repair after a move")
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
        // The daemon is running, just not this bundle's. Kept separate because the sentence
        // and the remedy are both different: nothing here is broken, there are simply two
        // copies of the app and the other one got there first.
        //
        // Only when the running executable really is inside an `.app`. The first version
        // stripped three path components unconditionally, which is right for
        // `<App>.app/Contents/MacOS/micpeg` and wrong for everything else — and one of the
        // "everything else" cases is reachable: delete the legacy plist by hand without
        // `launchctl bootout` and a daemon keeps running from `~/.local/bin/micpeg`, which
        // stripped down to the user's home directory. The banner would then have told them to
        // delete it.
        case .foreignBundle(let running):
            if let app = Self.enclosingAppBundle(of: running) {
                return .otherCopyRunning(at: app.path)
            }
            // Not an app: a daemon left over from the command-line install. Nothing of this
            // bundle's is keeping the microphone, which is the other sentence exactly.
            return .notKeeping
        // These three mean nothing is keeping the microphone: one sentence, one repair.
        // `.moved` reaches here only if the automatic repair above failed.
        case .notRegistered, .stale, .moved:
            return .notKeeping
        }
    }

    /// The `.app` enclosing an executable, if there is one. The daemon's own
    /// `enclosingAppBundle()` walks upward like this for the same reason; a fixed number of
    /// `deletingLastPathComponent()` calls only works for one layout.
    private static func enclosingAppBundle(of executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    @MainActor
    private func handle(_ action: AppModel.Banner.Action) {
        switch action {
        case .openLoginItems:
            AgentController.openLoginItems()
        case .repairAgent:
            run { Migration.repair() }
        case .migrateLegacy:
            run { Migration.migrate() }
        case .showActivity:
            // MainWindow opens it itself: opening a window takes a view's environment, which
            // this App-level handler does not have.
            break
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
            AgentController.report(outcome, label: "window action")
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
