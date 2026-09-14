// Opening a System Settings pane from the window.
//
// There is one of these in the app target already: SMAppService.openSystemSettingsLoginItems(),
// a real API that takes the user to Login Items. Privacy & Security has no equivalent, so the
// Microphone pane is reached by the URL scheme System Settings publishes for it — which is why
// this is a separate, named file rather than a URL literal dropped into a view: scripts/invariants
// .sh holds the product to two files that may construct a URL from a string at all, and a third
// one appearing is something reaching out on its own.
//
// app-ui.md, "Exception banners": "Telling a user to 'go to System Settings' without taking them
// there is where this flow usually dies." The login-item banner has had a button since stage 3.
// The microphone message named the pane and left the user to find it.

import AppKit

@MainActor
enum SystemSettings {
    /// Privacy & Security ▸ Microphone.
    ///
    /// The anchor after `?` is what selects the Microphone row rather than the top of Privacy &
    /// Security; docs/verification.md §29 records whether it still lands there, because an unvalidated
    /// URL scheme is exactly the kind of thing that degrades silently when the pane is reorganised.
    /// If it ever stops resolving, `NSWorkspace.open` returns false and the user is where they
    /// were — no worse than the sentence that used to stand alone here.
    @discardableResult
    static func openMicrophonePrivacy() -> Bool {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
