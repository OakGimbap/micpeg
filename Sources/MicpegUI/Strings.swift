// Every user-facing string in the app, and the one place a translation starts and finishes.
//
// app-ui.md: "Keep every user-facing string in one place so a Korean localization can follow
// without a rewrite. Do not hardcode strings inside view bodies." It has followed. Each string
// below is `String(localized:)`, its English text is the key, and
// `bundle/ko.lproj/Localizable.strings` holds the Korean. English needs no table: a key with no
// translation is shown as itself.
//
// The table is found in the main bundle, where scripts/bundle.sh puts it, and is not a SwiftPM
// resource. The `Bundle.module` accessor SwiftPM generates — read from the template inside this
// toolchain's swift-build — looks for its bundle at `Bundle.main.bundleURL`, which for an app is
// the root of the `.app` beside Contents/; then at an absolute path in the build directory; and
// then calls fatalError. Put there, the bundle cannot be signed ("unsealed contents present in
// the bundle root", measured on a scratch app); left out, a shipped app crashes on its first
// string.
//
// `static let` is right although the language can change. The frameworks choose a bundle's
// language as the process starts, so a new choice takes effect when the app reopens
// (AppLanguage.swift): one process, one language.
//
// scripts/l10n-check.sh compares the keys the compiler extracts from these calls with the Korean
// table, and fails on a key with no translation — whose silent form is one English sentence in
// the middle of a Korean window.
//
// The voice rules, also from app-ui.md, are applied here rather than remembered at each call
// site: sentence case for descriptive text and title case for buttons; full sentences take
// periods and short labels do not; second person, present tense, saying what happens rather
// than what the program does internally. No exclamation marks, no apologies, no jargon — and
// in particular none of the daemon's state names, which is why nothing below contains the
// words PINNED, YIELDED or BACKOFF.

import Foundation

public enum Copy {
    // MARK: Window

    /// The name, which is the same in every language, so it is not looked up.
    public static let appName = "Micpeg"

    // MARK: Onboarding

    public static let onboardingHeadline =
        String(localized: "When a Bluetooth headset connects, macOS moves your microphone to it.")
    public static let onboardingInstruction = String(localized: "Choose the microphone to keep.")
    /// The third line of the first run, and the only one that says what will be true afterwards.
    /// The headline states the problem and the instruction says what to do; someone who has just
    /// downloaded this still has no sentence telling them what they get. Deliberately says nothing
    /// about what connecting a headset does to *output* — docs/app-design.md embargoes the claim
    /// that pinning the input keeps AirPods in A2DP until it has been observed on hardware, and a
    /// line like this one is exactly where it would get smuggled in.
    public static let onboardingPromise = String(localized: """
        It stays selected from then on, including after you disconnect the headset.
        """)
    public static let deviceListFooter =
        String(localized: "Don't see it? Connect it and it will appear here.")
    public static func keepButton(_ device: String) -> String {
        String(localized: "Keep \(device)")
    }
    /// The same button with nothing selected yet. It is disabled in that state, so this is only
    /// ever read, never pressed — but `keepButton(Copy.noDevice)` rendered it as "Keep None",
    /// which is what a Mac whose only input is a Bluetooth headset shows on first run:
    /// `suggestedChoice` returns nil for a blocked transport, so nothing is preselected.
    public static let keepButtonNoChoice = String(localized: "Keep Microphone")
    public static let backgroundHelperNote = String(localized: """
        Enabling adds a background helper. macOS will tell you that a login item was added.
        """)

    // MARK: Removing Micpeg

    /// Removal lives in Settings because the main window answers "is it working?" and this is not
    /// that question. The copy never says "uninstall": the app bundle stays where it is, and a
    /// word that promises otherwise would be the second half of the problem this feature exists
    /// for — docs/verification.md §3 and §28 measured that dragging Micpeg to the Trash leaves the
    /// login item behind.
    public static let removeMicpegLabel = String(localized: "Remove Micpeg")
    public static let removeMicpegButton = String(localized: "Remove…")
    public static let removeMicpegTitle = String(localized: "Remove Micpeg?")
    public static let removeMicpegBody = String(localized: """
        This turns off the background helper, removes the login item, and deletes Micpeg's \
        settings and its log. Micpeg then quits and shows itself in the Finder, so you can move \
        it to the Trash.
        """)
    public static let removeMicpegConfirm = String(localized: "Remove")
    /// Worth its line. The helper's entire job is writing the default input, so anyone removing it
    /// wants to know whether their microphone is about to change. It is not.
    public static let removeMicpegFooter = String(localized: """
        Your microphone choice in System Settings is not changed.
        """)
    public static let removeFailed = String(localized: """
        Micpeg couldn't remove everything. Its background helper may still be set up.
        """)

    // MARK: Install location

    /// Shown instead of the whole window when Micpeg is running from a mounted disk image or from
    /// the translocated copy macOS makes of a quarantined app. No button: the only thing that
    /// could be offered is revealing the bundle in the Finder, and from a translocated launch that
    /// reveals a randomised path in a directory the user cannot act on — app-ui.md keeps file
    /// paths out of this window, and putting one in the Finder instead is the same thing.
    public static let cannotRunHereTitle =
        String(localized: "Micpeg needs to be in your Applications folder")
    public static let cannotRunHereBody = String(localized: """
        It's running from a location it can't be installed from. Quit Micpeg, move it to the \
        Applications folder, and open it from there.
        """)

    // MARK: Rows

    public static let outputLabel = String(localized: "Output")
    public static let inputLabel = String(localized: "Input")
    public static let noDevice = String(localized: "None")

    // MARK: Status

    public static func activeSummary(_ device: String) -> String {
        String(localized: "\(device) stays your microphone.")
    }
    public static func waitingSummary(_ device: String) -> String {
        String(localized: "\(device) isn't connected. It will be selected again when it is.")
    }
    public static func standingBySummary(_ chosen: String, target: String) -> String {
        String(localized: """
            You chose \(chosen), so \(target) is not being restored. Choosing \(target) again \
            resumes it.
            """)
    }
    public static func notInUseSummary(_ device: String) -> String {
        String(localized: "\(device) is connected, but another microphone is in use.")
    }
    public static let pausedSummary =
        String(localized: "Micpeg is paused. Your microphone can change freely.")
    public static let unconfiguredSummary = String(localized: "No microphone is chosen yet.")
    /// Not "still using the settings it loaded last": that is true of a helper that loaded a good
    /// file before this one broke, and false of one started since, which has none.
    public static let settingsUnreadableSummary = String(localized: """
        Until its settings file is fixed, Micpeg may not be keeping any microphone.
        """)

    // MARK: Banners

    public static let conflictTitle =
        String(localized: "Another program keeps changing your microphone")
    public static let conflictBody = String(localized: """
        Micpeg stopped competing with it. Quit the other program, or pause Micpeg.
        """)

    public static let approvalTitle = String(localized: "Micpeg is switched off in Login Items")
    public static let approvalBody = String(localized: """
        Its background helper can't run until you turn it back on. Only you can do that.
        """)
    public static let approvalAction = String(localized: "Open Login Items")

    public static let notRunningTitle = String(localized: "The background helper isn't running")
    public static let notRunningBody = String(localized: """
        Your microphone isn't being kept. Reconnecting usually fixes it.
        """)
    public static let notRunningAction = String(localized: "Reconnect")

    public static let orphanedTitle = String(localized: "The background helper won't start again")
    public static let orphanedBody = String(localized: """
        It's running now, but nothing will start it again once it stops. Reconnecting usually \
        fixes it.
        """)

    public static let legacyTitle = String(localized: "An older installation is still set up")
    public static let legacyBody = String(localized: """
        It was installed from the command line and needs to be replaced before this app can \
        take over.
        """)
    public static let legacyAction = String(localized: "Replace It")

    public static let otherCopyTitle = String(localized: "Another copy of Micpeg is doing this")
    public static func otherCopyBody(_ path: String) -> String {
        String(localized: """
            The copy at \(path) set up the background helper and it's running. Use that one, or \
            delete it and reopen this one.
            """)
    }

    public static func movedBody(_ from: String) -> String {
        String(localized: """
            Micpeg was moved from \(from). Its background helper has been reconnected.
            """)
    }
    public static let movedTitle = String(localized: "Micpeg reconnected after being moved")

    public static func blockedDeviceWarning(_ device: String) -> String {
        String(localized: """
            \(device) connects over Bluetooth, which Micpeg is set to ignore. Keeping it would \
            leave nothing to do.
            """)
    }
    /// app-ui.md, Unconfigured: "warn and confirm, do not silently disable". Asked once, when a
    /// device on a blocked transport is about to be kept.
    public static func keepBlockedTitle(_ device: String) -> String {
        String(localized: "Keep \(device)?")
    }
    public static let keepAnyway = String(localized: "Keep Anyway")

    public static let restoreFailedTitle =
        String(localized: "Your microphone couldn't be switched back")
    public static func restoreFailedBody(_ device: String) -> String {
        String(localized: "Micpeg tried to select \(device), and macOS didn't accept the change.")
    }
    public static let showActivity = String(localized: "Show Activity")

    public static let configUnreadableTitle =
        String(localized: "Micpeg's settings file can't be read")
    public static let configUnreadableBody = String(localized: """
        The background helper keeps the settings it loaded last, and has none if it has \
        restarted since. Fix or remove the file.
        """)

    /// While the app registers or repairs the background helper — up to half a minute when it
    /// has to wait out a spawn. Informational and without a button: the window used to show the
    /// helper-isn't-running failure through all of it, and its Reconnect started a second
    /// operation on top of the first.
    public static let workingTitle = String(localized: "Setting up the background helper")
    public static let workingBody = String(localized: "This can take a few seconds.")

    // MARK: Actions

    public static let changeMicrophone = String(localized: "Change Microphone")
    public static let pause = String(localized: "Pause")
    public static let resume = String(localized: "Resume")
    public static let done = String(localized: "Done")
    public static let cancel = String(localized: "Cancel")

    // MARK: Input test

    public static let startTest = String(localized: "Start Test")
    public static let stopTest = String(localized: "Stop Test")
    public static let testHint = String(localized: "Speak, and the level should move.")
    public static let silenceWarning = String(localized: "No sound is reaching this microphone.")
    public static let silenceHint =
        String(localized: "Check its mute switch and the input volume in System Settings.")
    /// Only for the built-in microphone. Measured: with the lid shut and an external display
    /// driving the Mac, the built-in microphone is still listed, still unmuted, still reports
    /// an input volume — and delivers buffers of exact zeros. Without this sentence the window
    /// sends the user hunting for a mute switch that is not the problem.
    public static let silenceHintBuiltIn = String(localized: """
        If the lid is closed, the built-in microphone isn't available. Otherwise check the \
        input volume in System Settings.
        """)

    // MARK: Activity

    public static let activityWindowTitle = String(localized: "Activity")
    public static let activityEmpty = String(localized: "Nothing Yet")
    public static let activityEmptyDetail =
        String(localized: "When your microphone changes, it appears here.")
    public static let today = String(localized: "Today")
    public static let yesterday = String(localized: "Yesterday")
    /// Under a minute. Seconds are never shown: a timestamp that changes every second is noise
    /// in a list the user reads once.
    public static let justNow = String(localized: "Just now")
    public static func minutesAgo(_ minutes: Int) -> String {
        String(localized: "\(minutes) min ago")
    }
    /// A sign and a number, which read the same in every language, so it is not looked up.
    public static func repeatCount(_ count: Int) -> String { "×\(count)" }
    public static func repeatCountSpoken(_ count: Int) -> String {
        String(localized: "\(count) times")
    }

    /// Visible labels for the rows whose picture is not a microphone moving. Two or three
    /// words: the badge and the device beside it say the rest.
    public static let pausedLabel = String(localized: "Paused")
    public static let resumedLabel = String(localized: "Resumed")
    public static let startedLabel = String(localized: "Started")
    public static let reconnectedLabel = String(localized: "Reconnected")
    public static let backInUseLabel = String(localized: "Back in use")
    public static let disconnectedLabel = String(localized: "Disconnected")
    public static let backedOffLabel = String(localized: "Stopped competing")
    public static func problemLabel(_ problem: Activity.Problem) -> String {
        switch problem {
        case .restoreFailed:      return String(localized: "Couldn't switch back")
        case .audioSystemLost:    return String(localized: "Lost the audio system")
        case .statusNotSaved:     return String(localized: "Status not saved")
        case .settingsUnreadable: return String(localized: "Settings unreadable")
        }
    }

    /// The whole row as one sentence, for VoiceOver. On screen the row is a picture — who
    /// acted, and which microphone moved where — and this is what that picture says. `target`
    /// names the kept microphone for the rows whose log line names no device.
    public static func activitySentence(_ kind: Activity.Kind, target: String) -> String {
        switch kind {
        case .restored(let to, let from?):
            return String(localized: """
                Moved your microphone back to \(to.name) from \(from.name).
                """)
        case .restored(let to, .none):
            return String(localized: "Moved your microphone back to \(to.name).")
        case .chose(let to, _):
            return String(localized: "You chose \(to?.name ?? target) in Micpeg.")
        case .switchedAway(let to):
            return String(localized: "You switched to \(to.name), so Micpeg stepped aside.")
        case .switchedBack:
            return String(localized: "You switched back to \(target).")
        case .paused:
            return String(localized: "You paused Micpeg.")
        case .resumed(let to, _):
            return String(localized: """
                You resumed Micpeg, and \(to?.name ?? target) is your microphone again.
                """)
        case .started:
            return String(localized: "Micpeg started.")
        case .reconnected:
            return String(localized: "\(target) is connected again.")
        case .backInUse:
            return String(localized: """
                The microphone you switched to went away, so \(target) is back in use.
                """)
        case .disconnected:
            return String(localized: "\(target) isn't connected.")
        case .backedOff:
            return String(localized: """
                Stopped competing with another program over the microphone.
                """)
        case .problem(let problem):
            return self.problem(problem)
        }
    }

    /// A row as VoiceOver reads it — on screen the row is a badge and a device moving, so this
    /// is the one place its words have to be complete — and as `MicpegApp activity` prints it.
    /// The repeat count is a sentence of its own: the row appends the time next, and "3 times
    /// 39 min ago" read as one run-on phrase through the accessibility API.
    public static func accessibilitySentence(for activity: Activity, target: String) -> String {
        let sentence = activitySentence(activity.kind, target: target)
        guard activity.count > 1 else { return sentence }
        return "\(sentence) \(repeatCountSpoken(activity.count))."
    }

    /// The daemon's failures, in the user's terms. `OSStatus` values and four-character codes
    /// stay in `Activity.raw` — app-ui.md keeps them out of the window.
    public static func problem(_ problem: Activity.Problem) -> String {
        switch problem {
        case .restoreFailed:
            return String(localized: "Tried to switch your microphone back and couldn't.")
        case .audioSystemLost:
            return String(localized: "Lost track of the audio system and restarted.")
        case .statusNotSaved:
            return String(localized: """
                Couldn't save its status, so what's shown here may be out of date.
                """)
        case .settingsUnreadable:
            return String(localized: """
                Couldn't read its settings and is using the last ones that worked.
                """)
        }
    }

    // MARK: Failures the window has to surface

    /// These are shown to the user, so they belong here rather than inline in the model and the
    /// audio code — the point of this file is that a translation can start and finish in it.
    /// Shorter than it was: the sentence used to end "Allow it in System Settings >
    /// Privacy & Security > Microphone", which named a destination and left the user to find it.
    /// The button beside it goes there.
    public static let microphonePermissionDenied =
        String(localized: "Micpeg needs permission to use the microphone.")
    public static let openMicrophoneSettings = String(localized: "Open Microphone Settings")
    public static let microphoneNoChannels =
        String(localized: "This microphone isn't providing any audio channels right now.")
    public static func microphoneCouldNotOpen(_ reason: String) -> String {
        String(localized: "The microphone could not be opened: \(reason)")
    }
    public static let deviceHasNoIdentifier =
        String(localized: "That device has no identifier to pin.")
    /// A change the CLI refused, in the window's own words. The CLI's output is written for a
    /// terminal and carries paths and decoding dumps; `AppModel.mutate` says how the cause is
    /// found instead.
    public static func changeFailedDisconnected(_ device: String) -> String {
        String(localized: "\(device) isn't connected any more.")
    }
    public static let changeFailedSettings =
        String(localized: "Micpeg's settings file can't be read, so nothing was changed.")
    public static let changeFailed = String(localized: "Micpeg couldn't make that change.")

    // MARK: Settings

    public static let languageLabel = String(localized: "Language")
    /// Following the system, as opposed to naming a language. The languages themselves are
    /// listed by their own names, in their own languages, which this table does not hold.
    public static let systemLanguage = String(localized: "System Language")
    public static let languageTakesEffect = String(localized: "Takes effect when Micpeg reopens.")
    public static let reopenNow = String(localized: "Reopen Now")
    public static func reopenFailed(_ reason: String) -> String {
        String(localized: "Micpeg couldn't reopen: \(reason)")
    }
    public static let logFileLabel = String(localized: "Log File")
    public static let showInFinder = String(localized: "Show in Finder")
    public static let activityFooter = String(localized: """
        Activity shows what happened to your microphone. The log file is the background \
        helper's full record.
        """)
    public static let versionLabel = String(localized: "Version")
    public static let licenseLabel = String(localized: "License")
    public static let viewLicense = String(localized: "View")
    public static let sourceCodeLabel = String(localized: "Source Code")
    public static let noThirdPartyCode = String(localized: """
        Micpeg uses no third-party code, so there are no other licenses to list.
        """)
}
