#!/bin/zsh
# Build micpeg and install it as a login LaunchAgent.
#
#   ./scripts/install.sh                      # build for this Mac's architecture
#   MICPEG_UNIVERSAL=1 ./scripts/install.sh   # build a universal (arm64 + x86_64) binary
#
# Installs to ~/.local/bin/micpeg, writes ~/Library/LaunchAgents/com.micpeg.agent.plist,
# and bootstraps the agent into your GUI session. No sudo — everything lives under $HOME.
set -e
cd "$(dirname "$0")/.."

ARGS=(-c release)
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
