#!/bin/zsh
# Build micpeg and install it as a login LaunchAgent.
#
# **This is the developer path, not the supported one.** Micpeg is distributed as a notarized
# Micpeg.app, which registers the same agent through SMAppService and is the only install a user
# is told about — see README.md. This script installs the standalone command-line agent instead,
# and the two cannot coexist: one launchd label, one registration path. docs/cli.md has the rest.
#
#   ./scripts/install.sh                      # build for this Mac's architecture
#   MICPEG_UNIVERSAL=1 ./scripts/install.sh   # build a universal (arm64 + x86_64) binary
#
# Installs to ~/.local/bin/micpeg, writes ~/Library/LaunchAgents/com.micpeg.agent.plist,
# and bootstraps the agent into your GUI session. No sudo — everything lives under $HOME.
set -e
cd "$(dirname "$0")/.."

# Micpeg.app registers the same label through ServiceManagement, and a hand-written agent under
# it boots the app's one out (docs/verification.md §8). The micpeg built below refuses as well,
# but only after the staging step has already replaced ~/.local/bin/micpeg — which, once the app
# has linked it, is the app's CLI.
if launchctl print "gui/$(id -u)/com.micpeg.agent" 2>/dev/null \
     | grep -q 'managed_by = com.apple.xpc.ServiceManagement'; then
  echo "error: Micpeg.app manages the background agent on this Mac. Update the app instead;" >&2
  echo "       this script installs the standalone command-line version." >&2
  exit 1
fi

# --product micpeg: a bare `swift build` also builds MicpegUI and MicpegApp, which ties
# installing the finished agent to the settings app compiling. settings-app has already failed
# to compile on the macOS 14 SDK this project advertises as its floor (CLAUDE.md, CI notes),
# so without this the minimum supported configuration cannot install the finished program.
ARGS=(-c release --product micpeg)
[ -n "$MICPEG_UNIVERSAL" ] && ARGS+=(--arch arm64 --arch x86_64)

swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/micpeg"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

# `micpeg install` only copies the binary when the destination is missing, so on an
# upgrade it would silently keep the old one. Stage it here instead.
#
# Write to a temp file and rename: copying directly onto a running executable fails
# with ETXTBSY, while rename(2) swaps the path atomically and leaves the running
# process on its old inode until launchd restarts it below.
DEST="$HOME/.local/bin/micpeg"
mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST.new"
chmod +x "$DEST.new"
mv -f "$DEST.new" "$DEST"
echo "installed: $DEST"

"$DEST" install

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo; echo "note: $HOME/.local/bin is not on your PATH — add it to run 'micpeg' directly." ;;
esac
