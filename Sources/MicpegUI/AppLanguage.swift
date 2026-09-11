// The app's display language, one of the two things it keeps in its own defaults domain — the
// other is RegistrationRecord's note of where it registered from.
//
// It is `AppleLanguages` in the app's own defaults domain, which is the key System Settings ›
// Language & Region › Applications writes when someone picks a language for one app. Using that
// key rather than one of our own makes the two settings one setting: a choice made in the
// Settings window shows up there, and one made there shows up here.
//
// The frameworks read it once, as the process starts — AppKit's menus, window titles, the
// microphone permission prompt, date formats, and every `String(localized:)` in Strings.swift —
// so a new choice takes effect when the app reopens. The daemon never reads it: its log is a
// format ActivityLog parses, and stays English.
//
// scripts/invariants.sh holds this file and RegistrationRecord.swift to being the only two in
// the app that name UserDefaults. Everything else the app changes goes through the CLI
// (app-design.md, "The GUI ↔ CLI contract"), and a third store would be one nobody decided to
// have.

import Foundation

public enum AppLanguage {
    private static let key = "AppleLanguages"

    /// The languages this bundle ships, the development language first. Outside a `.app` there
    /// is nothing to choose between.
    ///
    /// A set first: Foundation lists a language once for Info.plist's CFBundleLocalizations and
    /// again for its .lproj directory — measured on the built app, `["en", "ko", "ko"]` — and
    /// the picker showed Korean twice.
    public static var available: [String] {
        let shipped = Set(Bundle.main.localizations).subtracting(["Base"])
        let development = Bundle.main.developmentLocalization
        return shipped.sorted { ($0 == development ? 0 : 1, $0) < ($1 == development ? 0 : 1, $1) }
    }

    /// Whether the picker can do anything: a bundle to keep the preference for, and more than
    /// one language in it.
    public static var canChoose: Bool {
        Bundle.main.bundleIdentifier != nil && available.count > 1
    }

    /// The language chosen for this app alone, or nil when it follows the system.
    ///
    /// Read from the app's own domain. `UserDefaults.standard.array(forKey:)` falls through to
    /// the global domain and always answers with the system's list, so "follow the system"
    /// could never be read back. The stored value is matched to a shipped language by language
    /// code, because System Settings may store a region with it ("ko-KR"); one this bundle does
    /// not ship — only `defaults write` can put one there — reads as nil.
    public static var chosen: String? {
        guard let domain = Bundle.main.bundleIdentifier,
              let stored = UserDefaults.standard.persistentDomain(forName: domain)?[key]
                  as? [String],
              let first = stored.first else { return nil }
        let code = Locale(identifier: first).language.languageCode
        return available.first { Locale(identifier: $0).language.languageCode == code }
    }

    /// The choice this process started with, which is the one the frameworks are using.
    /// `MicpegSettingsApp.init` reads it first: a lazy `static let` read for the first time
    /// after the picker had changed the preference would record the new choice as the old one,
    /// and the window would stop saying that a reopen is needed.
    public static let chosenAtLaunch: String? = chosen

    /// Stores a choice, or removes it to follow the system. Takes effect at the next launch.
    public static func choose(_ language: String?) {
        if let language {
            UserDefaults.standard.set([language], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// A language's name in that language — "English", "한국어" — as macOS lists them, so that
    /// someone who cannot read the window's current language can still find their own.
    public static func name(of language: String) -> String {
        Locale(identifier: language).localizedString(forLanguageCode: language) ?? language
    }
}
