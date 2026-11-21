# ColonPop

A small native macOS menu-bar app for typing emoji by name. In a text field, type `:wav` and press Return to insert 👋. Typing the full `:wave:` works too.

## Install

1. Unzip `ColonPop-0.1.2-macOS.zip`, move **ColonPop.app** to **Applications**, then open it. If updating, choose **Quit ColonPop** from its menu-bar icon before replacing the previous version. The universal binary runs on Apple silicon and Intel Macs with macOS 13 or later.
2. Choose **Open Accessibility Settings…** in the setup window and enable **ColonPop**. If your Mac also requires Input Monitoring, the setup window shows that step. Reopen the app if macOS requests a restart.
3. From the smiley in the menu bar, choose **Test Picker…** to check the installed app. It types a few shortcodes in a temporary editor and checks the popup, Return, a row click, Escape, a closing colon and ordinary punctuation. Leave that window in front during the check. You can also open TextEdit and try `:tada:`.

**After an update:** If Setup still says **Enable ColonPop** when the old entry is already enabled, remove that entry in **System Settings → Privacy & Security → Accessibility**, then add the copy in **Applications**. Setup shows the version and path of the running copy. Ad-hoc builds have a different signing identity each time their code changes. [Apple’s code signing note](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

**Suggestions are on** means ColonPop has a working listener and can replace the shortcode in fields that allow Accessibility editing. Choose **Allow Keyboard Insertion…** in Setup for editors that need keyboard events. The smiley also lets you pause ColonPop or turn on **Open at Login**. If another system-wide shortcode picker is running, pause it while trying ColonPop.

The default build is ad-hoc signed. If Gatekeeper blocks a downloaded copy you trust, try opening it once, then use **System Settings → Privacy & Security → Open Anyway**. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## Use

Start a shortcode at the beginning of a field, after whitespace, after an opening bracket or quote, or just after another emoji. Ordinary punctuation in `12:30` and `https://` stays quiet. Suggestions appear at the caret when the editor exposes its screen position and near the pointer otherwise.

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

The catalog ships with the app. Search text lives in memory for the active query. The app uses neither the network nor the clipboard, and writes no typing history. It skips Secure Input and controls macOS identifies as password fields.

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

The script builds and verifies both architectures, creates the app icon, and produces `dist/ColonPop.app` and a versioned ZIP. The ZIP includes the app and its source in the `Source` folder. All emoji data is included for offline builds. For public distribution, set `CODESIGN_IDENTITY` to your Developer ID Application identity when running the script. Submit the signed ZIP for Apple notarization, staple the ticket to the app, then ZIP the stapled app for distribution. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## License and emoji data

ColonPop is available under the [MIT license](LICENSE). The Unicode strings, shortcodes, descriptions and tags in `Sources/ColonPop/Resources/emoji.tsv` are adapted from gemoji v4.1.0. The upstream Git blob for `db/emoji.json` is `65d4c8db9b110c241c7238ac0b0bbae6f8e6d0d7`. ColonPop adds descriptive aliases, country-flag shortcuts and five skin-tone modifiers. Emoji artwork is rendered by macOS. [gemoji source](https://github.com/github/gemoji/tree/v4.1.0) · [gemoji license](Licenses/gemoji.txt)
