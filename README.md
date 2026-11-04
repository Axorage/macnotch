# MacNotch

Lightweight native macOS app that turns the MacBook notch into a Dynamic-Island-style overlay.

## Build & run
    swift build                # debug build
    scripts/bundle.sh          # release build -> build/MacNotch.app (hardened runtime + Apple Events entitlement; signed with "MacNotch Dev" if present, else ad-hoc)
    scripts/run.sh             # bundle and open

Requires macOS 14+ and a Swift toolchain. The app is menu-bar only (no Dock icon); quit from the menu bar item.

## Permissions
MacNotch needs one permission: **Automation (Notes)**. Open **Settings > Permissions** (menu bar item > Settings) to see its live status, with a "Request Access" button (shows the real macOS prompt) or an "Open Settings" deep link. MacNotch only appears in System Settings > Privacy & Security > Automation after it has asked, so use Request Access first; Notes must be running for the request.

It uses Automation to list the notes of the Notes folder you choose (default "MacNotch") and to open the one you click in Notes. MacNotch never edits or writes your notes, and it needs no Full Disk Access and no Accessibility access.

### Signing and privacy grants
Ad-hoc signatures change with every build, so macOS treats each rebuild as a new app and Automation grants stop applying. For a stable identity run `scripts/make-signing-cert.sh` once (it creates a self-signed "MacNotch Dev" certificate in your login keychain; read it first), then rebuild. If MacNotch is missing or stale in Privacy & Security > Automation, reset and re-grant: `tccutil reset AppleEvents com.eortizd.macnotch`, relaunch, then click Continue in the Notes view.

## Behavior
The island draws nothing until you hover the hardware notch (springs out) or click it (sticky). Optionally show the timer in collapsed state: `defaults write com.eortizd.macnotch ui.showTimerWhileCollapsed -bool true`.
Spaces: the notch windows stay fixed while macOS slides between Spaces. `ui.pinAcrossSpaces` (default true) uses a PRIVATE SkyLight API (symbols resolved with dlsym at runtime; creates a top-level Space and delegates the windows to it, as boring.notch does). Every call is guarded; if it is unavailable the windows are simply left as-is. Disable with `defaults write com.eortizd.macnotch ui.pinAcrossSpaces -bool false`.
Debug flags: `--debug-mouse` (sensor/mouse-mode logs), `--debug-geometry` (print rect math), `--request-automation` (trigger the Notes permission request at launch). Launch with `open -n build/MacNotch.app --args --request-automation` after quitting any running copy; `open` ignores args if MacNotch is already running.

## Notes folder
Create a folder named **MacNotch** in Apple Notes (or pick another folder from the folder menu in the notch header); every unlocked note in it is listed in the notch, newest first (up to 500, scrolling). The list is fetched when the notch opens (at most every 30 s) and when you change folders. Click a note (or use the arrow keys and Return) to open it in the Notes app, brought to the front on that note; the notch then collapses. Editing is done in Notes.

## App icon
Source artwork: `Resources/AppIcon.png` (1254x1254, rounded square on transparent background; never modified, the prebuilt `AppIcon.icns`/`.iconset` there are no longer used by the bundle).

macOS 26+ shows icons whose artwork doesn't fill the system squircle on a light grey plate. `scripts/make-icon.swift` therefore crops the artwork to its squircle, fills the rounded corners by edge extension and writes an opaque full-bleed iconset; the system applies its own mask. `scripts/bundle.sh` runs it and caches the result in `build/icon/` (regenerated when the PNG or the script changes). `actool`/Icon Composer is not used since it needs full Xcode.
