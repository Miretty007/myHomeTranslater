#!/bin/zsh
# Build an isolated debug app and capture its own windows.
set -euo pipefail
cd "${0:A:h:h}"
swift build
binary_dir=$(swift build --show-bin-path)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$work/MyHomeTranslaterVerification.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cp -R Localizations/*.lproj "$app/Resources/"
cp "$binary_dir/myHomeTranslater" "$app/MacOS/"
cp Info.plist "$app/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.myhome.translater.verification' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSServices' "$app/Info.plist"
codesign --force --sign - --timestamp=none "${app:h}"
output=${1:-/tmp/myHomeTranslater-previews}
if [[ "${MHT_VERIFY_COLD:-0}" == 1 ]]; then
  swiftc tools/fixtures/empty-field.swift -o "$work/empty-field"
  export MHT_VERIFY_COLD_FIXTURE="$work/empty-field"
fi
language_args=()
if [[ -n ${MHT_VERIFY_LANGUAGE:-} ]]; then
  language_args=(-AppleLanguages "($MHT_VERIFY_LANGUAGE)")
fi
MHT_VERIFY="$output" "$app/MacOS/myHomeTranslater" "${language_args[@]}"
cat "$output/report.txt"
