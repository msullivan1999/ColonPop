#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/ColonPopBrowserCheck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/.build/browser-check-modules"
cp Tests/Browser/chrome.html Sources/ColonPop/Resources/emoji.tsv "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Check</string>
<key>CFBundleIdentifier</key><string>org.colonpop.tests.BrowserCheck</string>
<key>CFBundleName</key><string>ColonPop Browser Check</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$PWD/.build/browser-check-modules" \
    Sources/ColonPop/{BrowserPaste,Catalog,Composer,FocusField,Insertion,Keyboard,Picker}.swift \
    Tests/Browser/Check.swift -o "$app/Contents/MacOS/Check"
codesign --force --sign - "$app"
if [[ "${1:-}" == "--build-only" ]]; then echo "$app"; exit 0; fi
exec "$app/Contents/MacOS/Check" --exit-after-check
