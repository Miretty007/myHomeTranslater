#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
name=myHomeTranslater
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
if [[ ! -f Resources/Assets.car || ! -f Resources/AppIcon.icns || -n $(find Icon -type f -newer Resources/Assets.car -print -quit) ]]; then
  tools/make_icon.sh
fi
app="dist/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp "$binary_dir/$name" "$app/Contents/MacOS/"
cp Resources/{AppIcon.icns,Assets.car} "$app/Contents/Resources/"
cp -R Localizations/*.lproj "$app/Contents/Resources/"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app"
codesign --verify --strict "$app"
echo "Built $PWD/$app"
