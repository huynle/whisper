#!/bin/sh
# `swift test` needs Xcode's Testing module; the Command Line Tools alone do not have it.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec swift test "$@"
