// Where this copy of Micpeg is running from, and whether it can be installed from there.
//
// Stage 5 ships a DMG, and the DMG introduces a user error the source build never could: opening
// Micpeg.app from the mounted disk image instead of dragging it to Applications first. macOS then
// runs it *translocated* — from a read-only copy at a randomised path under
// /private/var/folders/…/AppTranslocation/ — and that path is gone the moment the image is
// ejected. Registering from there is the worst kind of failure this project knows: it succeeds.
// RegistrationRecord writes down a path that will not exist, launchd gets a BundleProgram inside
// a mount point, and the next launch reads the recorded bundle as missing and repairs a move that
// never happened, taking the label from whatever copy legitimately holds it.
//
// The test is for the symptom, not the mechanism. A translocated bundle sits on a read-only
// nullfs mount; a bundle opened from a mounted image sits on a read-only, removable volume. One
// pair of resource values catches both, needs no private API and no path-substring match on
// "/AppTranslocation/", and keeps working if Apple changes how translocation is implemented.
// (SecTranslocateIsTranslocatedURL exists and is deprecated; docs/verification.md §29 records
// whether it and this check ever disagree on hardware.)
//
// **Not "is it in /Applications".** docs/verification.md §28 measured that on macOS 26.6 launchd
// resolves the program relative to the bundle identifier, so a move does not break a registration,
// and MicpegAppMain's `.moved` handling repairs the case that does. Warning someone running from
// ~/Downloads about a problem that does not exist on the measured OS is noise, and it would break
// running build/Micpeg.app during development. One tier, and only for a volume that cannot hold
// an installation.

import Foundation

enum InstallLocation {
    /// True when this bundle is somewhere an installation cannot live.
    ///
    /// Fails open. If the volume cannot be interrogated the answer is "this is fine": a false
    /// positive blocks the whole app for someone whose Mac is merely unusual, and the condition
    /// this guards against is loud and specific, not a default.
    static func isUnusable(_ bundle: URL = Bundle.main.bundleURL) -> Bool {
        guard let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey,
                                                               .volumeIsRemovableKey]) else {
            return false
        }
        return values.volumeIsReadOnly == true || values.volumeIsRemovable == true
    }

    /// For the unified log, so a report can say which of the two it was without the window
    /// putting a randomised path on screen (app-ui.md: no file paths in that window).
    static func describe(_ bundle: URL = Bundle.main.bundleURL) -> String {
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey,
                                                          .volumeIsRemovableKey])
        return """
        bundle: \(bundle.path)
        volume read-only: \(values?.volumeIsReadOnly.map(String.init(describing:)) ?? "unknown")
        volume removable: \(values?.volumeIsRemovable.map(String.init(describing:)) ?? "unknown")
        """
    }
}
