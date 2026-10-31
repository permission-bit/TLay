# macOS release status

Terminal Layout 0.3 is a local, unsandboxed macOS menu bar application, not a Mac App Store submission.
It requires macOS 13 or later. The build script produces a universal Apple Silicon / Intel app.
The SwiftUI app is self-contained and does not require Rust or a network connection.
Optional folder discovery uses the macOS osascript interpreter to query terminal metadata.

## Mac App Store limitation

Apple requires Mac App Store apps to be appropriately sandboxed (App Review Guideline 2.4.5).
Apple's App Sandbox documentation lists accessibility APIs in assistive apps, sending Apple Events to
arbitrary apps, and modifying other apps' preferences among sandbox restrictions. The current
window manager requires cross-application Accessibility access, and prompt installation modifies
the user's shell configuration outside an app container.

These features need a separately assessed, Apple-accepted distribution architecture before a
Mac App Store submission. Enabling the sandbox entitlement alone does not make them work.
Do not submit this build as “App Store ready” or add an unsandboxed helper to bypass the restriction.
Public window-management APIs are used, but that does not guarantee acceptance.

Sources checked October 25, 2026:

- [App Review Guidelines, 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

## Current development workflow

    bash test-app.sh
    bash build-app.sh
    open "Terminal Layout.app"

For a faster local build:

    ARCHITECTURES=arm64 bash build-app.sh

An ad-hoc signature is used by default. It is suitable for local testing, not public distribution.
Accessibility consent may need to be re-enabled after rebuilding an ad-hoc-signed application.
The app never grants or resets macOS permissions itself.

## Before a public release

1. Resolve distribution: assess the sandbox constraints with Apple, or distribute a Developer ID
   signed and notarized application directly.
2. Use a real bundle identifier and your own Apple Developer team in the Xcode project.
   Keep the signing identity stable between releases.
3. Archive in Xcode, sign using the intended distribution identity and validate the archive.
   The provided project has the sandbox disabled because the existing features need that access.
   It does not contain a preconfigured App Store target.
4. For direct distribution, use a Developer ID signature, hardened runtime, a secure timestamp and
   notarization. The current build script's optional SIGNING_IDENTITY is not a complete release pipeline.
5. Have native speakers review all twelve translations, especially safety/reset copy and accessibility.
6. Test on real Intel and Apple Silicon Macs, macOS 13 and the current macOS version, multiple displays,
   long translated labels, Arabic right-to-left layout, denied/revoked Accessibility permissions,
   minimum-size windows, custom zsh configurations and existing prompt themes.
7. Prepare the privacy policy, support URL, screenshots, product metadata, final 1024 px store artwork,
   and any privacy manifests required by the exact APIs/SDKs used by the release build.

## Local data and reset contract

Settings: ~/Library/Application Support/com.rastafari.terminallayout/preferences.json

Shell backups: the Shell Backups subdirectory beside the settings file. They can include private shell
configuration and are stored in a private directory with file permissions 0600. No data is uploaded.

“Reset to defaults” restores English, first-launch language selection, Terminal and iTerm2, four
quarters, and 12 pt spacing. It removes only this app's marked prompt sections and the exact known
output of the earlier CLI. It preserves unrelated shell content and edits made after installation.
Every shell modification has a separate backup. Corrupt/incomplete prompt markers stop the operation.
Reset does not replace the full .zshrc, reset other apps, delete backups, revoke system permissions,
change existing window positions, or change fonts.

“Restore positions” separately restores the original window geometry captured during the current
app session. Closed windows and windows that reject resizing cannot always be restored.
Prompt removal takes effect in a new shell.

Version 0.3 additionally defaults to automatic arrangement and four native Bigger Text steps for
terminal windows. Reset restores those defaults, disables directory grouping, and unregisters the
app's optional login startup. Existing window text sizes remain unchanged.

The menu bar app remains alive after closing Settings and scans selected apps approximately once
per second. It only rearranges windows after topology/configuration changes, font adjustments or an
explicit request. Text scaling uses the target terminal's native Accessibility menu action when its
new window has focus; successful steps are persisted so restarting the app does not apply them again.
Changing preferences cancels in-flight mutations. Failed placement gets only bounded retries.
Multiple copies of the background app are prevented with a per-user file lock.

“Open at login” is opt-in and uses SMAppService.mainApp. Test registration, revocation, and launch
with a stable real signing identity and a stable installed app location before shipping.

Directory grouping affects this app's own overview and the regular desktop layout. It does not
modify Mission Control's window arrangement or install an F3 hook. Apple documents grouping by
application in Mission Control; no path-group customization is used here.
Folder detection reads only local working directories and session TTY metadata, not terminal
contents. It may require Automation consent for Terminal/iTerm2. Discovery is off by default and
runs separately so a permission request never delays automatic layout or font sizing.
Unknown folders stay unknown; remote SSH directories are not inferred.

Additional sources:

- [Mission Control](https://support.apple.com/en-gb/guide/mac-help/mh35798/mac)
- [SMAppService registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [iTerm2 scripting](https://iterm2.com/documentation-scripting.html)
