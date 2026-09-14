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

// `@MainActor`, and AppDelegate below, for the reason MainWindow gives. Here it is
// `@State private var model = AppModel()`: a main-actor initializer in a property initializer,
// which the Swift 5.10 in CI rejects in an unmarked type — it rejected MainWindow's `InputTest()`
// the same way.
@main
@MainActor
struct MicpegSettingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        // Exits the process if an argument was given. See Headless.swift.
        Headless.runIfRequested()
        // Before any window exists that could change it. AppLanguage.swift says why.
        _ = AppLanguage.chosenAtLaunch
    }

    var body: some Scene {
        // A `Window`, not a `WindowGroup`: one main window, by construction. A group offers
        // File ▸ New Micpeg Window (⌘N) and makes as many as it is asked for — verification.md
        // §22 opened a second one — and `CommandGroup(replacing: .newItem) {}` would only hide
        // the item and leave the group able to make more. Apple's documentation calls `Window`
        // "a single, unique window", and says that as the primary scene "the app quits when the
        // window closes", which AppDelegate below asks for anyway.
        Window(Copy.appName, id: MainWindow.sceneID) {
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

        // After the main window, so that one stays the scene that opens at launch. A singleton
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

        // ⌘,. For this scene SwiftUI enables the Settings… item in the app menu (Apple's
        // `Settings` documentation). SettingsWindow.swift says what is in it, and why one pane.
        Settings {
            SettingsWindow(onReopen: reopen, onRemove: remove)
        }
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
        // First, and it returns. A translocated copy — one opened from the mounted DMG instead of
        // being dragged to Applications — has no recorded bundle path of its own, so it reads as
        // `.moved` and the automatic repair below would hand the label to a bundle that ceases to
        // exist when the image is ejected, taking it from whichever copy legitimately holds it.
        // The early return is the guard; a flag that only changed what the window drew would not
        // be one. InstallLocation.swift says what is tested and why it is the symptom.
        if InstallLocation.isUnusable() {
            AgentController.report(InstallLocation.describe(), label: "cannot run from here")
            model.setCannotRunHere(true)
            return
        }

        // Off the main actor: this forks `launchctl print` and waits for it, then makes two
        // synchronous ServiceManagement round trips to backgroundtaskmanagementd. On the main
        // thread that is the window's first frame blocked for as long as btmd takes.
        let survey = await Task.detached { InstallSurvey.take() }.value
        // Nothing here overwrites `.working`: an operation the user started while the survey
        // ran reports its own verdict when it ends (`run(_:)`).
        guard model.agent != .working else { return }
        if case .moved(let from) = survey.verdict {
            // Through the same state `run(_:)` sets, so the window says what is happening for
            // the half-minute this can take, and a Reconnect pressed meanwhile does nothing.
            model.setAgent(.working)
            let outcome = await Task.detached { Migration.repair() }.value
            AgentController.report(outcome, label: "auto-repair after a move")
            model.setAgent(outcome.ok ? .repairedAfterMove(from: from)
                                      : condition(after: outcome))
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
        // `<App>.app/Contents/MacOS/micpeg` and wrong for everything else — deleting the legacy
        // plist without `launchctl bootout` left a daemon running from `~/.local/bin/micpeg`,
        // which stripped down to the user's home directory, and the banner told them to delete
        // it. That daemon is `.legacyPresent` now, so an app should always be found here; the
        // fallback stays so that no banner ever names a path that is not one.
        case .foreignBundle(let running):
            if let app = InstallSurvey.enclosingAppBundle(of: running) {
                return .otherCopyRunning(at: app.path)
            }
            return .notKeeping
        // A daemon is running and nothing will start it again: the orphan a Finder move leaves,
        // or one whose copy of the app is gone. "The background helper isn't running" would be
        // false today; the repair is the same. Unreached on macOS 26.6, where no move purges the
        // Background Task Management records (§28); the banner behind it is still unobserved.
        case .stale where survey.job.pid != nil:
            return .orphaned
        // These three mean nothing is keeping the microphone: one sentence, one repair.
        // `.moved` reaches here only if the automatic repair above failed.
        case .notRegistered, .stale, .moved:
            return .notKeeping
        }
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
    ///
    /// Not when the agent already runs from here: the CLI's SIGHUP has told it about the choice,
    /// and a register() over a healthy registration starts no new daemon for the confirmation to
    /// see, so it would wait out its whole timeout and report a failure.
    @MainActor
    private func enableAfterFirstChoice() {
        guard model.agent != .healthy else { return }
        run { Migration.migrate() }
    }

    /// One registration operation at a time. `.working` is set before the operation starts and
    /// replaced by its verdict, so a second press — Reconnect during the launch repair, a
    /// double-click on Replace It — finds it and does nothing. There was no guard: the second
    /// unregister killed the daemon the first operation was waiting for.
    @MainActor
    private func run(_ body: @escaping @Sendable () -> Migration.Outcome) {
        guard model.agent != .working else { return }
        model.setAgent(.working)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { body() }.value
            AgentController.report(outcome, label: "window action")
            model.setAgent(condition(after: outcome))
            model.reloadAll()
        }
    }

    /// What the window says after an operation: the survey's verdict — except that an operation
    /// that did not confirm a new daemon is never shown as healthy. The survey can read HEALTHY
    /// off the old process, still running on the inode a move carried, beside a record the
    /// operation has just rewritten and a registration `.enabled` again, while the next spawn
    /// fails. `Outcome.ok` says so, and this used to drop it.
    @MainActor
    private func condition(after outcome: Migration.Outcome) -> AppModel.AgentCondition {
        let condition = condition(for: outcome.survey)
        return !outcome.ok && condition == .healthy ? .notKeeping : condition
    }

    // MARK: - Removing Micpeg

    /// Tear the installation down, then leave. Returns a sentence for the Settings window only
    /// when something survived — a removal that worked has already quit the app, so there is no
    /// window left to show a success in, which is the right ending for this particular button.
    ///
    /// Uninstall.swift says why this cannot be a `micpeg` subcommand and what the order is.
    @MainActor
    private func remove() async -> String? {
        let outcome = await Task.detached(priority: .userInitiated) { Uninstall.run() }.value
        AgentController.report(outcome, label: "remove Micpeg")
        guard outcome.ok else {
            model.setAgent(condition(after: outcome))
            model.reloadAll()
            return Copy.removeFailed
        }
        Uninstall.revealAndQuit()
        return nil
    }

    // MARK: - Language

    /// Launches the app again and quits this copy, for a new language. The frameworks choose a
    /// bundle's language as the process starts (AppLanguage.swift), so nothing short of a new
    /// process changes the menus, the window titles or the microphone prompt. The daemon is
    /// launchd's and does not notice.
    ///
    /// A new instance, because opening an app that is already running only brings it forward.
    /// Returns why it failed, for the Settings window to show.
    @MainActor
    private func reopen() async -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                                             configuration: configuration)
        } catch {
            return error.localizedDescription
        }
        NSApp.terminate(nil)
        return nil
    }
}

/// docs/app-design.md, "Process model": quitting the app must never look like it stops the
/// feature, and there is nothing for the GUI to do once its window is gone. launchd holds the
/// daemon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Tabbing is the other way a Mac app grows windows: View ▸ Show Tab Bar, and Window ▸ Merge
    /// All Windows, which would fold the main and Activity windows into one frame of two sizes.
    /// Off before the first window exists, so AppKit never adds either item.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
