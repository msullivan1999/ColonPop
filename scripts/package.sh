#!/bin/bash
set -euo pipefail

previous_app=""
notary_profile=""
usage() { echo 'Usage: package.sh [--upgrade-from PREVIOUS.app] [--notarize KEYCHAIN_PROFILE]' >&2; exit 2; }
while [[ $# -gt 0 ]]; do
    [[ -n "${2:-}" && "$2" != --* ]] || usage
    case "$1" in
        --upgrade-from)
            [[ -d "$2" ]] || { echo "Previous application does not exist at $2." >&2; exit 2; }
            previous_app="$(cd "$2" && pwd -P)" ;;
        --notarize) notary_profile="$2" ;;
        *) usage ;;
    esac
    shift 2
done
cd "$(dirname "$0")/.."

identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" && -e .git ]]; then
    identity="$(git config --local --get colonpop.signingIdentity || true)"
fi
if [[ -n "$notary_profile" ]]; then
    # Resolve a name or fingerprint to a distribution identity before using a private key.
    identity="$(security find-identity -v -p codesigning | awk -F'"' -v wanted="$identity" '
        $2 ~ /^Developer ID Application:/ {
            split($1, fields, " ")
            if (wanted == "" || wanted == $2 || toupper(wanted) == fields[2]) print fields[2]
        }' | sort -u)"
    case "$identity" in
        "") echo 'A valid Developer ID Application certificate and private key are required for notarization.' >&2; exit 1 ;;
        *$'\n'*) echo 'Choose one Developer ID Application identity with CODESIGN_IDENTITY or colonpop.signingIdentity.' >&2; exit 1 ;;
    esac
fi

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
sign_options=(--force --options runtime)
if [[ -n "$notary_profile" ]]; then sign_options+=(--timestamp); fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
    identity="-"
    echo 'Ad-hoc signing ties Accessibility approval to this exact program. Use a consistent signing certificate for updates.' >&2
fi
codesign "${sign_options[@]}" --sign "$identity" "$app"
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
zip_metadata=--norsrc
if [[ -n "$notary_profile" ]]; then
    submission="$stage/notary.zip"
    result="$stage/notary-result.plist"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$submission"
    notary_exit=0
    xcrun notarytool submit "$submission" --keychain-profile "$notary_profile" --wait --output-format plist > "$result" || notary_exit=$?
    request_id="$(/usr/bin/plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    notary_status="$(/usr/bin/plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    echo "Apple notarization ${request_id:-request}: ${notary_status:-no status returned}."
    if [[ "$notary_exit" -ne 0 || "$notary_status" != "Accepted" ]]; then exit 1; fi
    xcrun stapler staple "$app"
    zip_metadata=--sequesterRsrc
fi
for file in .gitignore LICENSE README.md Package.swift Licenses/gemoji.txt Packaging/Info.plist \
        Sources/ColonPop/*.swift Sources/ColonPop/Resources/emoji.tsv Tests/ColonPopTests/*.swift \
        Tests/Browser/Check.swift Tests/Browser/chrome.html scripts/{check-upgrade,test-chrome,package}.sh scripts/make-icon.swift; do
    mkdir -p "$release_dir/Source/$(dirname "$file")"
    cp "$file" "$release_dir/Source/$file"
done
ditto -c -k "$zip_metadata" "$release_dir" "$stage/$name"
if [[ -n "$notary_profile" ]]; then
    ditto -x -k "$stage/$name" "$stage/unpacked"
    xcrun stapler validate "$stage/unpacked/ColonPop.app"
    codesign --verify --deep --strict --all-architectures "$stage/unpacked/ColonPop.app"
fi
ditto "$app" "$output_dir/ColonPop.app"
mv -f "$stage/$name" "$output_dir/$name"
echo "$output_dir/$name"
