#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

output_dir="$PWD/dist"
mkdir -p "$output_dir" "$PWD/.build"
stage="$(mktemp -d "$PWD/.build/package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"
release_dir="$stage/release"
app="$release_dir/ColonPop.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/.build/release-modules"

for arch in arm64 x86_64; do
    xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 -O -whole-module-optimization \
        -module-name ColonPop -sdk "$sdk" -target "$arch-apple-macosx13.0" \
        -module-cache-path "$PWD/.build/release-modules" -Xlinker -dead_strip \
        Sources/ColonPop/*.swift -o "$stage/ColonPop-$arch"
done
lipo -create "$stage/ColonPop-arm64" "$stage/ColonPop-x86_64" -output "$app/Contents/MacOS/ColonPop"
cp Packaging/Info.plist "$app/Contents/"
cp Sources/ColonPop/Resources/emoji.tsv "$app/Contents/Resources/"
cp LICENSE Licenses/gemoji.txt "$app/Contents/Resources/"
xcrun swift -module-cache-path "$PWD/.build/release-modules" scripts/make-icon.swift "$app/Contents/Resources/ColonPop.icns"
codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict --all-architectures "$app"
plutil -lint "$app/Contents/Info.plist"
lipo "$app/Contents/MacOS/ColonPop" -verify_arch arm64 x86_64
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
name="ColonPop-$version-macOS.zip"
for file in .gitignore LICENSE README.md Package.swift Licenses/gemoji.txt Packaging/Info.plist \
        Sources/ColonPop/*.swift Sources/ColonPop/Resources/emoji.tsv Tests/ColonPopTests/*.swift \
        Tests/Browser/Check.swift Tests/Browser/chrome.html scripts/test-chrome.sh scripts/make-icon.swift scripts/package.sh; do
    mkdir -p "$release_dir/Source/$(dirname "$file")"
    cp "$file" "$release_dir/Source/$file"
done
ditto -c -k --norsrc "$release_dir" "$stage/$name"
ditto "$app" "$output_dir/ColonPop.app"
mv -f "$stage/$name" "$output_dir/$name"
echo "$output_dir/$name"
