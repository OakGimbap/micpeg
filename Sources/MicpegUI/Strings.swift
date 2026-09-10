// Every user-facing string in the app.
//
// app-ui.md: "Keep every user-facing string in one place so a Korean localization can follow
// without a rewrite. Do not hardcode strings inside view bodies."
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

    public static let appName = "Micpeg"

    // MARK: Onboarding

    public static let onboardingHeadline =
        "When a Bluetooth headset connects, macOS moves your microphone to it."
    public static let onboardingInstruction = "Choose the microphone to keep."
    public static let deviceListFooter = "Don't see it? Connect it and it will appear here."
    public static func keepButton(_ device: String) -> String { "Keep \(device)" }
    public static let backgroundHelperNote =
        "Enabling adds a background helper. macOS will tell you that a login item was added."

    // MARK: Rows

    public static let outputLabel = "Output"
    public static let inputLabel = "Input"
    public static let noDevice = "None"

    // MARK: Status

    public static func activeSummary(_ device: String) -> String {
        "\(device) stays your microphone."
    }
    public static func waitingSummary(_ device: String) -> String {
        "\(device) isn't connected. It will be selected again when it is."
    }
    public static func standingBySummary(_ chosen: String, target: String) -> String {
        "You chose \(chosen), so \(target) is not being restored. Choosing \(target) again "
        + "resumes it."
    }
    public static let pausedSummary = "Micpeg is paused. Your microphone can change freely."
    public static let unconfiguredSummary = "No microphone is chosen yet."

    // MARK: Banners

    public static let conflictTitle = "Another program keeps changing your microphone"
    public static let conflictBody =
        "Micpeg stopped competing with it. Quit the other program, or pause Micpeg."

    public static let approvalTitle = "Micpeg is switched off in Login Items"
    public static let approvalBody =
        "Its background helper can't run until you turn it back on. Only you can do that."
    public static let approvalAction = "Open Login Items"

    public static let notRunningTitle = "The background helper isn't running"
    public static let notRunningBody =
        "Your microphone isn't being kept. Reconnecting usually fixes it."
    public static let notRunningAction = "Reconnect"

    public static let legacyTitle = "An older installation is still set up"
    public static let legacyBody =
        "It was installed from the command line and needs to be replaced before this app can "
        + "take over."
    public static let legacyAction = "Replace It"

    public static func movedBody(_ from: String) -> String {
        "Micpeg was moved from \(from). Its background helper has been reconnected."
    }
    public static let movedTitle = "Micpeg reconnected after being moved"

    public static func blockedDeviceWarning(_ device: String) -> String {
        "\(device) connects over Bluetooth, which Micpeg is set to ignore. Keeping it would "
        + "leave nothing to do."
    }

    public static let configUnreadableTitle = "Micpeg's settings file can't be read"
    public static let configUnreadableBody =
        "The background helper is still using the settings it loaded last. Fix or remove the "
        + "file to change them."

    // MARK: Actions

    public static let changeMicrophone = "Change Microphone"
    public static let pause = "Pause"
    public static let resume = "Resume"
    public static let done = "Done"
    public static let cancel = "Cancel"

    // MARK: Input test

    public static let startTest = "Start Test"
    public static let stopTest = "Stop Test"
    public static let testHint = "Speak, and the level should move."
    public static let silenceWarning = "No sound is reaching this microphone."
    public static let silenceHint =
        "Check its mute switch and the input volume in System Settings."
    /// Only for the built-in microphone. Measured: with the lid shut and an external display
    /// driving the Mac, the built-in microphone is still listed, still unmuted, still reports
    /// an input volume — and delivers buffers of exact zeros. Without this sentence the window
    /// sends the user hunting for a mute switch that is not the problem.
    public static let silenceHintBuiltIn =
        "If the lid is closed, the built-in microphone isn't available. Otherwise check the "
        + "input volume in System Settings."
    public static let meterAccessibilityHidden = ""

    // MARK: Activity

    public static let activityTitle = "Recent activity"
    public static let activityEmpty = "Nothing yet."
    public static func restored(to device: String, displacing other: String?) -> String {
        if let other { return "Moved your microphone back to \(device) from \(other)." }
        return "Moved your microphone back to \(device)."
    }
    public static func steppedAside(to device: String) -> String {
        "You chose \(device), so Micpeg stepped aside."
    }
    public static let resumedActivity = "Your chosen microphone is back in use."
    public static func pinnedActivity(_ device: String) -> String {
        "Selected \(device)."
    }
    public static let targetMissingActivity = "Your chosen microphone isn't connected."
    public static let backedOffActivity =
        "Stopped competing with another program over the microphone."
    public static let startedActivity = "The background helper started."
}
