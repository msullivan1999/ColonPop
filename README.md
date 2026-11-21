# ColonPop

A small native macOS menu-bar app for typing emoji by name. In a text field, type `:wav` and press Return to insert 👋. Typing the full `:wave:` works too.

## Install

1. Unzip `ColonPop-0.1.4-macOS.zip`, move **ColonPop.app** to **Applications**, then open it. If updating, choose **Quit ColonPop** from its menu-bar icon before replacing the previous version. The universal binary runs on Apple silicon and Intel Macs with macOS 13 or later.
2. Choose **Open Accessibility Settings…** in the setup window and enable **ColonPop**. If your Mac also requires Input Monitoring, the setup window shows that step. Reopen the app if macOS requests a restart.
3. From the smiley in the menu bar, choose **Test Picker…** to check the installed app. The check opens a temporary editor. If keyboard insertion is enabled, it tests the popup, Return, a row click, Escape, a closing colon and ordinary punctuation automatically. Otherwise, type the example shown in the window. You can also open TextEdit and try `:tada:`.

**After an update**

If Setup says **Enable ColonPop** while System Settings shows ColonPop switched on, expand **Already enabled?** to see the running app’s path. Choose **Open Accessibility Settings…**. Some macOS versions call this pane **Device Control and Data Access**. Select the old **ColonPop** row, remove it with the minus button, then use the plus button to add the copy in Applications. Reopen ColonPop if macOS asks. Updates between ad-hoc builds can require this one-time approval for each changed binary. [Apple’s code signing note](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

When Setup says **Suggestions are on** or **Ready to type**, press Return for **Done**, or choose **Test Picker…** to try it. If a field keeps the shortcode, expand **Trouble inserting?** in the **Suggestions are on** window and choose **Allow Keyboard Insertion…**. The smiley in the menu bar also lets you pause ColonPop or turn on **Open at Login**. If another system-wide shortcode picker is running, pause it while trying ColonPop.

The default build is ad-hoc signed. If Gatekeeper blocks a downloaded copy you trust, try opening it once, then use **System Settings → Privacy & Security → Open Anyway**. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## Use

Start a shortcode at the beginning of a field, after whitespace, after an opening bracket or quote, or just after another emoji. A bare `:` offers favorites. The first Down arrow highlights the first one. Return keeps its usual behavior until a row is highlighted. Ordinary punctuation in `12:30` and `https://` stays quiet. Suggestions appear at the caret when the editor exposes its screen position and near the pointer otherwise.

| Input | Result |
| --- | --- |
| `:thu` | Search names and keywords as you type |
| ↑ or ↓ | Move through up to six matches |
| Return, Tab or a click | Insert the highlighted or clicked emoji |
| Closing `:` | Insert an exact shortcode, including aliases such as `:+1:` |
| Escape | Dismiss and keep the original text |
| Backspace | Edit the query normally |

Try `:joy:` 😂, `:white_check_mark:` ✅, `:flag-au:` 🇦🇺 or `:wave::skin-tone-4:` 👋🏽. Search covers 1,870 Unicode emoji plus five skin-tone modifiers. The Slack desktop app keeps its built-in picker.

## How it works

ColonPop uses Swift, AppKit, a Quartz session event tap and the macOS Accessibility API. The suggestions panel leaves keyboard focus in the host app. During a search, the host receives the literal shortcode as you type. Changing apps or fields, clicking elsewhere, or using an editing shortcut cancels the search.

Return, Tab and row clicks use the same insertion path. ColonPop gives the editor time to process the last keystroke and rechecks the focused field. When macOS permits it, ColonPop sends the edit to that application as keyboard events. Otherwise it attempts a native Accessibility edit and checks that the emoji appeared. When an editor reports a stale caret, ColonPop can verify the selected shortcode before inserting the emoji. For simple controls with limited text APIs, it can use the tracked shortcode length. Custom controls need to expose an identifiable text input and support one of those editing methods.

In Google Chrome, ColonPop selects the exact shortcode and asks the browser to replace that range. When the browser lacks a direct replacement action, ColonPop briefly puts the emoji on the system clipboard and invokes Chrome’s Paste command. It restores the previous items and formats after the edit, provided the clipboard still belongs to that operation. A newer copy takes precedence. For a clipboard marked confidential or promised, or too large to preserve, ColonPop leaves it alone and uses keyboard insertion if available. Clipboard managers may see the temporary emoji.

The catalog ships with the app. Search text stays in memory for the active query. ColonPop works offline, writes no typing history, and skips Secure Input and controls macOS identifies as password fields.

## Build

On a Mac with the Swift 5.9 or later toolchain and the macOS SDK, run the following from the project directory.

```sh
swift test
./scripts/package.sh
```

To run the cross-application check against a release from an interactive Mac desktop, quit other copies of ColonPop and run the following. It uses the packaged menu-bar app and a separate native editor. A successful run exits with 0, a failed check with 1, and an unavailable desktop or missing test permission with 77.

```sh
dist/ColonPop.app/Contents/MacOS/ColonPop --test-picker --exit-after-check
```

To check Chrome manually, open `Tests/Browser/chrome.html` in Chrome and try each of the three fields. The page tracks Return and form submissions locally. For a repeatable cross-process check, run `./scripts/test-chrome.sh` on an interactive Mac with Chrome installed and Accessibility allowed for the test application. That check sends Return to the production event handler in memory, then verifies Chrome’s real input event, surrounding text, and rich formatting. Its isolated test application is built under `.build`.

The packaging script builds both architectures, creates the app icon, and produces `dist/ColonPop.app` and a versioned ZIP with the matching Swift source. All emoji data is included for offline builds.

For public distribution, run `./scripts/package.sh --notarize PROFILE_NAME` with a Developer ID Application certificate and its private key installed, and an existing `notarytool` keychain profile. The script uses the configured certificate or the single valid Developer ID Application identity. It signs with a secure timestamp, submits the app to Apple, waits for acceptance, staples the ticket, and verifies the ticket and signature after extracting the final ZIP. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

For repeated builds in one checkout, save your chosen signing certificate with `git config --local colonpop.signingIdentity "CERTIFICATE NAME OR FINGERPRINT"`. `CODESIGN_IDENTITY` overrides this setting. Use the same identity for subsequent builds. Moving from an ad-hoc build to a certificate-signed build still needs a one-time approval.

To package an update, run `./scripts/package.sh --upgrade-from /path/to/previous/ColonPop.app`. Packaging stops before replacing the output if the candidate fails the previous app’s signing requirement. You can check two existing apps with `./scripts/check-upgrade.sh PREVIOUS.app UPDATE.app`. Both checks use macOS code signing tools and leave system permissions untouched.

## License and emoji data

ColonPop is available under the [MIT license](LICENSE). The Unicode strings, shortcodes, descriptions and tags in `Sources/ColonPop/Resources/emoji.tsv` are adapted from gemoji v4.1.0. The upstream Git blob for `db/emoji.json` is `65d4c8db9b110c241c7238ac0b0bbae6f8e6d0d7`. ColonPop adds descriptive aliases, country-flag shortcuts and five skin-tone modifiers. Emoji artwork is rendered by macOS. [gemoji source](https://github.com/github/gemoji/tree/v4.1.0) · [gemoji license](Licenses/gemoji.txt)
