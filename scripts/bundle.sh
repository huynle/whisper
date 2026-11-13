#!/bin/sh
# Builds Whisper.app in build/ and signs it with the "Whisper Dev" certificate from the login Keychain.
# A stable signature keeps the app's Microphone, Accessibility and Input Monitoring permissions across rebuilds.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${CONFIG:-release}"

IDENTITY="$(security find-certificate -c "Whisper Dev" -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | awk '/SHA-1/ { print $3; exit }')"
if [ -z "$IDENTITY" ]; then
    echo "No \"Whisper Dev\" code-signing certificate in the login Keychain." >&2
    exit 1
fi

swift build -c "$CONFIG" --product Whisper
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Whisper"

APP=build/Whisper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Whisper"
cp App/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier com.huynle.whisper "$APP"
codesign --verify --strict "$APP"
echo "Built and signed $APP"
