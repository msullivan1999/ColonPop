#!/bin/bash
set -euo pipefail

previous_app=""
if [[ $# -ne 0 ]]; then
    if [[ $# -ne 2 || "$1" != "--upgrade-from" ]]; then
        echo 'Usage: package.sh [--upgrade-from PREVIOUS.app]' >&2
        exit 2
    fi
    previous_app="$2"
    if [[ ! -d "$previous_app" ]]; then
        echo "Previous application does not exist at $previous_app." >&2
        exit 2
    fi
    previous_app="$(cd "$previous_app" && pwd -P)"
fi
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
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" && -e .git ]]; then
    identity="$(git config --local --get colonpop.signingIdentity || true)"
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
    identity="-"
    echo 'Ad-hoc signing ties Accessibility approval to this exact program. Use a consistent signing certificate for updates.' >&2
fi
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict --all-architectures "$app"
if [[ -n "$previous_app" ]]; then
    ./scripts/check-upgrade.sh "$previous_app" "$app"
elif [[ -d "$output_dir/ColonPop.app" ]]; then
    if ! ./scripts/check-upgrade.sh "$output_dir/ColonPop.app" "$app"; then
        echo 'This package will need fresh approval. Use --upgrade-from to require a compatible update.' >&2
    fi
fi
plutil -lint "$app/Contents/Info.plist"
lipo "$app/Contents/MacOS/ColonPop" -verify_arch arm64 x86_64
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
name="ColonPop-$version-macOS.zip"
for file in .gitignore LICENSE README.md Package.swift Licenses/gemoji.txt Packaging/Info.plist \
        Sources/ColonPop/*.swift Sources/ColonPop/Resources/emoji.tsv Tests/ColonPopTests/*.swift \
        Tests/Browser/Check.swift Tests/Browser/chrome.html scripts/{check-upgrade,test-chrome,package}.sh scripts/make-icon.swift; do
    mkdir -p "$release_dir/Source/$(dirname "$file")"
    cp "$file" "$release_dir/Source/$file"
done
ditto -c -k --norsrc "$release_dir" "$stage/$name"
ditto "$app" "$output_dir/ColonPop.app"
mv -f "$stage/$name" "$output_dir/$name"
echo "$output_dir/$name"
