#!/bin/sh
# Builds Whisper.app, installs it as ~/Applications/Whisper.app and starts it from there.
# The first launch of an installed copy turns on "Open Whisper at login"; Settings → General can turn it off.
# Run it again to update: the running copy is quit and replaced.
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh

DEST="$HOME/Applications/Whisper.app"
mkdir -p "$HOME/Applications"
# Quit, not kill: the launch agent restarts Whisper when it ends any other way.
if pgrep -x Whisper >/dev/null; then
    osascript -e 'tell application id "com.huynle.whisper" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -x Whisper >/dev/null || break; sleep 0.2; done
    pgrep -x Whisper >/dev/null && { echo "Whisper did not quit; quit it from its menu and run this again." >&2; exit 1; }
fi
rm -rf "$DEST"
ditto build/Whisper.app "$DEST"
codesign --verify --strict "$DEST"
# macOS ties the launch agent to the build it was registered with, and takes a moment to accept a new
# self-signed build, so register it for this one until Whisper is running through it (a crash later is then
# restarted). Without the agent, open it as a normal app.
started=no
for _ in 1 2 3; do
    "$DEST/Contents/MacOS/Whisper" --register-agent >/dev/null 2>&1 || break
    for _ in $(seq 1 16); do pgrep -x Whisper >/dev/null && { started=yes; break; }; sleep 0.5; done
    [ $started = yes ] && break
done
[ $started = yes ] || open "$DEST"
echo "Installed and started $DEST"
