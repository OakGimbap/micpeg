#!/bin/zsh
# Build micpin and install it as a login LaunchAgent.
#
#   ./scripts/install.sh                  # build for this Mac's architecture
#   MICPIN_UNIVERSAL=1 ./scripts/install.sh   # build a universal (arm64 + x86_64) binary
#
# `micpin install` copies the built binary to ~/.local/bin/micpin, writes
# ~/Library/LaunchAgents/com.micpin.agent.plist, and bootstraps it into your GUI
# session. It does not need sudo — everything lives under your home directory.
set -e
cd "$(dirname "$0")/.."

ARGS=(-c release)
[ -n "$MICPIN_UNIVERSAL" ] && ARGS+=(--arch arm64 --arch x86_64)

swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/micpin"

[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }
echo "built: $BIN"
"$BIN" install
