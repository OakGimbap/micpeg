// The Settings window, ⌘,: the app's language, the way into Activity and the daemon's own log,
// and what Micpeg is — its version, its license, where its source lives.
//
// One pane. Apple's HIG on settings, read from its DocC JSON (the web page renders in
// JavaScript): "If your settings window doesn't have multiple panes, use the title App Name
// Settings." Seven rows do not need a toolbar of panes, and panes would bring the same page's
// "restore the most recently viewed pane" with them — one more value stored, for seven rows.
//
// Activity is a button here rather than a pane, for a reason from the same page: a settings
// window "accommodates the size of the current pane, people don't need to expand the window".
// Activity is a list the user sizes (verification.md §23), so it keeps its own window.
//
// The container and the sizing are the main window's, for the reasons MainWindow.swift gives.

import AppKit
import SwiftUI

public struct SettingsWindow: View {
    /// Launches the app again and quits this copy, or says why it could not. It belongs to the
    /// app target, as registration does: MicpegUI draws, and does not decide the process's life.
    private let onReopen: () async -> String?

    @State private var language = AppLanguage.chosen
    @State private var reopenFailure: String?
    @State private var showingLicense = false
    @Environment(\.openWindow) private var openWindow

    public init(onReopen: @escaping () async -> String?) {
        self.onReopen = onReopen
    }

    public var body: some View {
        Form {
            languageSection
            activitySection
            aboutSection
        }
        .formStyle(.grouped)
        // Not a scrolling window. Sized to its content below, it had nothing to scroll to and
        // scrolled anyway: the viewport was 374 pt and the content a fraction taller, so the
        // scroll bar had a point of travel — enough for a trackpad, which is what was reported.
        // With scrolling disabled the scroll bar is gone from the accessibility tree, and
        // `.fixedSize` still sizes the window: 460×407, 447 while the Reopen row is shown, and
        // back (verification.md §25). The main window does the same, for the same reason
        // (MainWindow.swift).
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingLicense) {
            LicenseSheet(text: About.license ?? "")
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker(Copy.languageLabel, selection: $language) {
                Text(Copy.systemLanguage).tag(String?.none)
                ForEach(AppLanguage.available, id: \.self) { code in
                    Text(AppLanguage.name(of: code)).tag(Optional(code))
                }
            }
            .disabled(!AppLanguage.canChoose)
            .onChange(of: language) { _, chosen in
                AppLanguage.choose(chosen)
                reopenFailure = nil
            }
            // Compared with the choice this process started with, not with the last one made
            // here: choosing a language and then choosing back needs no reopen, and the row goes
            // away again.
            if language != AppLanguage.chosenAtLaunch {
                LabeledContent(Copy.languageTakesEffect) {
                    Button(Copy.reopenNow) {
                        Task { reopenFailure = await onReopen() }
                    }
                }
            }
        } footer: {
            if let reopenFailure {
                Text(Copy.reopenFailed(reopenFailure))
            }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            LabeledContent(Copy.activityWindowTitle) {
                Button(Copy.showActivity) { openWindow(id: ActivityWindow.sceneID) }
            }
            LabeledContent(Copy.logFileLabel) {
                Button(Copy.showInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([DaemonPaths.log])
                }
                // Checked when the window draws. The daemon writes this file from its first
                // start, so it is missing only where the background helper has never run.
                .disabled(!FileManager.default.fileExists(atPath: DaemonPaths.log.path))
            }
        } footer: {
            Text(Copy.activityFooter)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            if let version = About.version {
                LabeledContent(Copy.versionLabel, value: version)
            }
            if let license = About.license {
                LabeledContent(Copy.licenseLabel) {
                    HStack {
                        Text(About.name(of: license))
                        Button(Copy.viewLicense) { showingLicense = true }
                    }
                }
            }
            LabeledContent(Copy.sourceCodeLabel) {
                Link(About.repositoryName, destination: About.repository)
            }
        } footer: {
            Text(Copy.noThirdPartyCode)
        }
    }
}

/// What the About rows show, read from the bundle rather than written here a second time.
enum About {
    /// "0.1.0 (1)", from Info.plist. Nil outside a `.app`.
    static var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }

    /// The repository's LICENSE, which scripts/bundle.sh copies into Contents/Resources: the MIT
    /// terms ask for the notice in every copy, and a built app is a copy. Never translated — it
    /// is the license. Nil outside a `.app`.
    static let license: String? = Bundle.main.url(forResource: "LICENSE", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The license's own first line, "MIT License", so that its name is written in one place:
    /// the file that is the license.
    static func name(of license: String) -> String {
        license.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? license
    }

    static let repository = URL(string: "https://github.com/OakGimbap/micpeg")!

    /// "github.com/OakGimbap/micpeg" — where the link goes, rather than a word that hides it.
    static var repositoryName: String {
        (repository.host() ?? "") + repository.path()
    }
}

/// The license in full, in a sheet.
///
/// The file's paragraphs are hard-wrapped at about 78 columns, and shown as they are in a
/// narrower sheet each of those lines would wrap again partway along. So each paragraph is
/// joined into one line and wrapped to the sheet instead. The words are the file's.
struct LicenseSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            ScrollView {
                Text(Self.reflowed(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button(Copy.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
    }

    static func reflowed(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").joined(separator: " ") }
            .joined(separator: "\n\n")
    }
}

// MARK: - Previews

#Preview("Settings") {
    SettingsWindow(onReopen: { nil })
}
