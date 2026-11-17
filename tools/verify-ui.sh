#!/bin/zsh
# Build an isolated debug app and capture its own windows.
set -euo pipefail
cd "${0:A:h:h}"
swift build
binary_dir=$(swift build --show-bin-path)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/MyHomeTranslaterVerification.app/Contents"
mkdir -p "$app/MacOS"
cp "$binary_dir/myHomeTranslater" "$app/MacOS/"
cp Info.plist "$app/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.myhome.translater.verification' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSServices' "$app/Info.plist"
codesign --force --sign - --timestamp=none "${app:h}"
output=${1:-/tmp/myHomeTranslater-previews}
MHT_VERIFY="$output" "$app/MacOS/myHomeTranslater"
cat "$output/report.txt"
