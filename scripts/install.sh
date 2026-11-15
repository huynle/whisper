#!/bin/sh
# Builds Whisper.app, installs it as ~/Applications/Whisper.app and starts it from there.
# The first launch of an installed copy turns on "Open Whisper at login"; Settings → General can turn it off.
# Run it again to update: the running copy is quit and replaced.
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh

DEST="$HOME/Applications/Whisper.app"
mkdir -p "$HOME/Applications"
if pgrep -x Whisper >/dev/null; then
    pkill -x Whisper
    while pgrep -x Whisper >/dev/null; do sleep 0.2; done
fi
rm -rf "$DEST"
ditto build/Whisper.app "$DEST"
codesign --verify --strict "$DEST"
open "$DEST"
echo "Installed and started $DEST"
