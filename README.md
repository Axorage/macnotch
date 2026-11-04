# MacNotch

Lightweight native macOS app that turns the MacBook notch into a Dynamic-Island-style overlay.

## Build & run
    swift build                # debug build
    scripts/bundle.sh          # release build -> build/MacNotch.app (hardened runtime + Apple Events entitlement; signed with "MacNotch Dev" if present, else ad-hoc)
    scripts/run.sh             # bundle and open

Requires macOS 14+ and a Swift toolchain. The app is menu-bar only (no Dock icon); quit from the menu bar item.

## Permissions
Open **Settings > Permissions** (menu bar item > Settings) to see live status for each permission below, with a "Request Access" button (shows the real macOS prompt) or "Open Settings" deep link. MacNotch only appears in System Settings > Privacy & Security > Automation / Accessibility after it has asked, so use Request Access first. Full Disk Access is never auto-listed: click "Show MacNotch in Finder", then in Full Disk Access click **+** and choose MacNotch. Notes must be running for the Automation request.

- **Automation (Notes):** approve the prompt so MacNotch can read the Notes folder you choose (default "MacNotch") via Apple Events, and save your edits when you change a note in the notch. Notes are written only when you type in the inline editor; the editor supports rich text (bold, italic, underline, strikethrough, titles and headings, links, monospace, bullet and numbered lists; shortcuts ⌘B / ⌘I / ⌘U / ⇧⌘X) and has a "Revert to Original" button after edits. Notes with attachments, images, tables, checklists, colors or other formatting MacNotch cannot save losslessly, and locked notes, stay read-only there (use Edit in Notes).
- **Accessibility (optional):** lets "Edit in Notes" put the cursor on the line you were editing. Without it the note still opens, just without the cursor jump. MacNotch asks only when you click "Open Settings" on the in-notch hint; it reads and sets the cursor of the Notes text area and nothing else. Grant it in System Settings > Privacy & Security > Accessibility.
- **Full Disk Access:** needed only if reading the Notes database directly. Add build/MacNotch.app in System Settings > Privacy & Security > Full Disk Access.

### Signing and privacy grants
Ad-hoc signatures change with every build, so macOS treats each rebuild as a new app and Automation grants stop applying. For a stable identity run `scripts/make-signing-cert.sh` once (it creates a self-signed "MacNotch Dev" certificate in your login keychain; read it first), then rebuild. If MacNotch is missing or stale in Privacy & Security > Automation, reset and re-grant: `tccutil reset AppleEvents com.eortizd.macnotch` (and `tccutil reset Accessibility com.eortizd.macnotch`), relaunch, then click Continue in the Notes view.

## Behavior
The island draws nothing until you hover the hardware notch (springs out) or click it (sticky). Optionally show the timer in collapsed state: `defaults write com.eortizd.macnotch ui.showTimerWhileCollapsed -bool true`.
Spaces: the notch windows stay fixed while macOS slides between Spaces. `ui.pinAcrossSpaces` (default true) uses a PRIVATE SkyLight API (symbols resolved with dlsym at runtime; creates a top-level Space and delegates the windows to it, as boring.notch does). Every call is guarded; if it is unavailable the windows are simply left as-is. Disable with `defaults write com.eortizd.macnotch ui.pinAcrossSpaces -bool false`.
Debug flags: `--debug-mouse` (sensor/mouse-mode logs), `--debug-geometry` (print rect math), `--request-automation` (trigger the Notes permission request at launch), `--request-accessibility` (trigger the Accessibility prompt at launch). Launch with `open -n build/MacNotch.app --args --request-automation` after quitting any running copy; `open` ignores args if MacNotch is already running.

## Notes folder
Create a folder named **MacNotch** in Apple Notes; its notes appear in the notch.

## App icon
Source artwork: `Resources/AppIcon.png` (1254x1254, rounded square on transparent background; never modified, the prebuilt `AppIcon.icns`/`.iconset` there are no longer used by the bundle).

macOS 26+ shows icons whose artwork doesn't fill the system squircle on a light grey plate. `scripts/make-icon.swift` therefore crops the artwork to its squircle, fills the rounded corners by edge extension and writes an opaque full-bleed iconset; the system applies its own mask. `scripts/bundle.sh` runs it and caches the result in `build/icon/` (regenerated when the PNG or the script changes). `actool`/Icon Composer is not used since it needs full Xcode.
