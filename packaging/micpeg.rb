# The Homebrew Cask, kept here as the source of truth and copied into the tap.
#
# It lives in its own tap — github.com/OakGimbap/homebrew-tap, as Casks/micpeg.rb — rather than in
# homebrew-cask upstream, whose notability rule (roughly 30 forks or 75 stars, or a recognised
# vendor) rejects a new single-maintainer project on sight. The file transfers nearly verbatim if
# that ever changes.
#
#   brew install --cask oakgimbap/tap/micpeg
#
# `version` and `sha256` are filled in per release. The digest cannot be predicted: hdiutil embeds
# timestamps, so two builds of identical source produce different images. Take it from the
# published Micpeg-<version>.dmg.sha256, never from a local build.
cask "micpeg" do
  version "0.9.0"
  sha256 "REPLACE_WITH_THE_PUBLISHED_DIGEST"

  url "https://github.com/OakGimbap/micpeg/releases/download/v#{version}/Micpeg-#{version}.dmg"
  name "Micpeg"
  desc "Keeps a chosen microphone as the macOS default input"
  homepage "https://github.com/OakGimbap/micpeg"

  livecheck do
    url :url
    strategy :github_latest
  end

  # LSMinimumSystemVersion is 14.0, because @Observable is.
  depends_on macos: ">= :sonoma"

  app "Micpeg.app"

  # `launchctl:` boots the job out, which stops the daemon. It does not, and cannot, clear the
  # Background Task Management record or the Login Items entry behind it: that is not a file, and
  # the only thing that clears it is SMAppService.unregister() from inside the app. See `caveats`.
  uninstall launchctl: "com.micpeg.agent",
            quit:      "com.micpeg.app"

  # ~/.local/bin/micpeg is deliberately absent from this list. It is usually the symlink the app's
  # `link` command made into the bundle, but it may equally be a standalone command-line install
  # the user built themselves, and a cask cannot tell the two apart. Micpeg's own Remove can, and
  # does.
  zap trash: [
    "~/.config/micpeg",
    "~/Library/Logs/micpeg.log",
    "~/Library/Preferences/com.micpeg.app.plist",
    "~/Library/Saved Application State/com.micpeg.app.savedState",
  ]

  caveats <<~EOS
    Micpeg's background helper is a login item the app registers. Removing the app does not
    remove that registration — measured on macOS 26.6, it survives moving the app, dragging it
    to the Trash, and emptying the Trash.

    To remove Micpeg completely, open it first and use Settings (#{"⌘"},) -> Remove Micpeg,
    then `brew uninstall --cask micpeg`.
  EOS
end
