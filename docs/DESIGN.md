# MacNotch — UX/UI Design Spec

Target: macOS 14+, SwiftUI + AppKit, Swift Package. Citations use `file.md › Heading` (files in `apple-design/references/hig/`). Anything not cited is **judgment**.

## 1. Thesis, signature, restraint

**Thesis.** The notch is dead pixels; MacNotch makes it a quiet, glanceable tool. It should feel like the hardware grew a little, not like an app window appeared. (`design-principles.md › Simplicity`: every element earns its place; `› Agency`: stay out of the way.)

**Signature element: the wings.** When a Pomodoro runs, the black notch grows two wings as one continuous shape: a phase glyph on the left, `mm:ss` on the right. The timer reads as part of the hardware. This is what the app is remembered by. Everything else is deliberately plain.

**Restraint rules**
1. Surface is pure opaque black `#000000` (sRGB 0,0,0, alpha 1), indistinguishable from the hardware notch; no keyline, card fills, or overlays. No gradients, blur, materials, or tint.
2. At most one accent color on screen, and only while a Pomodoro is running or paused.
3. No animation at idle. Nothing loops. The only recurring work is a 1 Hz timer tick, and only while a timer runs.
4. Two type weights per view (regular and semibold). Sizes come from the table in 4.2.
5. Motion only for state changes the user caused (open/close, switch, start/pause) or a phase ending.
6. No shadow in the collapsed state. A collapsed shadow would break the hardware illusion and cost an offscreen pass.

## 2. States and dimensions

### 2.1 Notch geometry (read at runtime, never hardcode)
```swift
let h = screen.safeAreaInsets.top                         // notch height (pt)
let w = screen.frame.width
      - (screen.auxiliaryTopLeftArea?.width  ?? 0)
      - (screen.auxiliaryTopRightArea?.width ?? 0)        // notch width (pt)
```
- Pick the screen with `safeAreaInsets.top > 0` (built-in). Recompute on `NSApplication.didChangeScreenParametersNotification`. Round to device pixels (`backingScaleFactor`).
- Typical values are about 185 x 32 pt (14"/16" MacBook Pro). Treat them as test fixtures only.
- **No notch** (external display, older Mac): use the primary screen, a virtual notch of `200 x NSStatusBar.system.thickness` (24 pt) centered at the top edge. The virtual notch has the same states, but the collapsed shape shows only when a Pomodoro is running (otherwise nothing is drawn, so non-notch users see no black blob). Judgment.
- Content must never sit behind the hardware notch (`layout.md › Desktop (macOS)`). The central `notchW` zone is empty in every state.

### 2.2 State table
| State | Size (w x h) | Top ear radius | Bottom radius | Content |
|---|---|---|---|---|
| Collapsed | `notchW x notchH` | 0 | 9 (tunable constant `hardwareCornerRadius`; compare against the real bezel) | none |
| Live activity | `(notchW + 2·52) x notchH` | 6 | 12 | leading glyph, trailing time |
| Expanded | `680 x 210` | 14 | 26 | band + inline Notes / Pomodoro panes |

- **Wing width 52 pt** per side. This is the floor of Apple's compact presentation width (`live-activities.md › macOS dimensions` points to the iOS table: 52.33 to 62.33 x 36.67). Keep the wings equal so the two halves read as one piece of information (`live-activities.md › Compact presentation`).
- **Ears.** The top corners flare outward (concave, like a Dynamic Island). The shape's bounding box includes the ears; the body is inset by `topEar` at the top edge. One `NotchShape: Shape` with `animatableData = AnimatablePair<Double, AnimatablePair<Double, Double>>` (topEar, bottom, width factor) lets SwiftUI interpolate between states with a single path.
- **Concentric corners.** Inner container radius = outer bottom radius − padding: 26 − 16 = 10. Use 10 for content cards and 8 for list rows (`live-activities.md › Creating Live Activity layouts`: concentric placement).
- **Window.** One borderless `NSPanel` (`.nonactivatingPanel`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`) at the **maximum** expanded size plus a 32 pt margin (bottom and sides) that fully contains the expanded shadow (radius 10 + y 4), pinned top-center. The window never resizes during animation (cheapest option). Override `hitTest` so clicks outside the current shape pass through to the apps below.

### 2.3 Spacing grid (8 pt base)
Tokens: `xs 4`, `s 8`, `m 12`, `l 16`, `xl 24`.
- Expanded horizontal padding 24, bottom padding 16, gap between controls 8.
- Minimum hit target 28 x 28 pt (`accessibility.md › Mobility`: macOS default 28, minimum 20).
- Live wings: outer padding 10, **inner padding 0** (content snug against the notch; `live-activities.md › Compact presentation`).

### 2.4 Expanded layout (inline, 680 x 210; no tabs)
Notes (left) and Pomodoro (right) are always visible together on hover (`design-principles.md › Simplicity`, `› Agency`: nothing hidden behind a tab). Island frame = 680 + 2 x 14 ear; content inset 14 + 24 horizontally.
```
y   0 ─ 34  Band = notchH. Wings only: "Notes" title (left), phase title (right). Centre 190 + 2 x 12 pt stays empty.
y  34 ─ 40  6 pt gap
y  40 ─ 194 Panes (154 pt): Notes (flexible, ~336) | 24 pt gap, no divider | Pomodoro (272)
y 194 ─ 210 16 pt bottom padding
```
Panes are separated by space only (`layout.md › Best practices`: group related content with whitespace; judgment on dropping the rule). Notes = 4 rows of 38 pt; Pomodoro = 112 pt ring + controls column. On a non-notch screen the band is 28 pt and the same layout applies.

## 3. Color tokens

The island is **always black, in both light and dark system appearances**. This is the "rare case" of a permanently dark UI (`dark-mode.md › Best practices`) and matches Apple's opaque-black Dynamic Island (`live-activities.md › Choosing colors`). Do not add an in-app appearance setting. Contrast figures are WCAG ratios against `#000000`, computed.

| Token | Value | Ratio | Use |
|---|---|---|---|
| `surface` | `#000000` | n/a | island fill |
| `textPrimary` | `#FFFFFF` | 21.0:1 | titles, time, body |
| `textSecondary` | white 70% (`#B2B2B2`) | 9.9:1 | snippets, hints |
| `textTertiary` | white 50% (`#808080`) | 5.3:1 | metadata, 10–11 pt only |
| `textDisabled` | white 30% | 2.4:1 | disabled controls only (exempt, never for information) |
| `fillHover` | white 8% | n/a | row/button hover |
| `fillPressed` | white 14% | n/a | pressed |
| `separator` | white 12% | n/a | 0.5 pt rules |
| ~~`keyline`~~ | removed | n/a | the hardware notch has no outline; any edge stroke reads lighter than the bezel. Island = pure opaque #000000, no stroke, no overlay |
| `accentWork` | `#FF6B57` (warm coral) | 7.5:1 | Focus phase |
| `accentShort` | `#30D158` (system green, dark) | 10.4:1 | Short Break |
| `accentLong` | `#64D2FF` (system cyan, dark) | 12.2:1 | Long Break |
| `amber` | `#FFBF00` | 12.6:1 | Focus timer glyph beside the "Focus" title in the Pomodoro band (right wing) only; same in Increase Contrast |
| `warning` | `#FFD60A` (system yellow, dark) | about 15:1 | error glyphs |

All text tokens meet 4.5:1 (`accessibility.md › Vision`). The small-text target of 7:1 (`dark-mode.md › Dark Mode colors`) holds for primary and secondary. Tertiary is limited to non-essential metadata.

**Increase Contrast** (`NSWorkspace.accessibilityDisplayShouldIncreaseContrast`): secondary becomes white 85%, tertiary white 70%, separator white 30%.

**Accent justification.** Phase colors are the only color in the product, so they carry meaning. Warm coral means effort, green means rest, cool cyan means a longer, calmer rest. They are the system's dark-appearance hues, so they behave well with Increase Contrast (`color.md › System colors`). Color is never the only signal (`color.md › Inclusive color`, `accessibility.md › Vision`): each phase also has a distinct glyph (3.3) and a text label. The three also differ in luminance (7.5 / 10.4 / 12.2). We ignore the user's macOS accent color on purpose: the island is a fixed black brand surface, and its controls use white fills, not `controlAccentColor`.

**Bold color** is allowed only for the expanded ring, the glyph, and the progress bar, as in `live-activities.md › Choosing colors`. The time itself stays white.

## 4. Typography and icons

### 4.1 Rules
SF Pro via system styles. macOS has no Dynamic Type (`typography.md › Desktop (macOS)`), so sizes are fixed. Minimum 10 pt (`typography.md › Ensuring legibility`). Use Regular, Medium, Semibold only; no light weights. Compact live-activity text is medium weight or heavier (`live-activities.md › Best practices`).

### 4.2 Tokens
| Token | SwiftUI | Size / weight | Use |
|---|---|---|---|
| `timeHero` | `.system(size: 40, weight: .semibold).monospacedDigit()` | 40 / Semibold | expanded timer |
| `timeCompact` | `.system(size: 13, weight: .semibold).monospacedDigit()` | 13 / Semibold | live-activity time |
| `rowTitle` | `.body.weight(.semibold)` | 13 / Semibold | note title, detail title |
| `body` | `.body` | 13 / Regular, line spacing 2 | note body |
| `snippet` | `.subheadline` | 11 / Regular | snippet, empty-state body |
| `tab` | `.subheadline.weight(.semibold)` | 11 / Semibold | band titles, phase label, Next button |
| `button` | `.callout.weight(.semibold)` | 12 / Semibold | text buttons |
| `meta` | `.footnote` | 10 / Regular | hidden-note count, session count |

Timer format: system countdown format (`m:ss` under 10 min), monospaced digits, fixed width (sized for `00:00`, 40 pt at 13 pt) so the right wing never jitters. Rationale: the running time is rendered by `Text(timerInterval:countsDown:)`, which the system updates with zero app wakeups; a custom `mm:ss` string would need a 1 Hz app timer. Paused/idle uses plain `mm:ss`, capped at `99:59`. Empty-state titles use `rowTitle`.

### 4.3 SF Symbols (all `.semibold`, scale medium; weights matched to adjacent text per `sf-symbols.md › Weights and scales`)
| Purpose | Symbol | Size |
|---|---|---|
| Notes title | `note.text` | 13 |
| Start | `play.fill` | 16 |
| Pause | `pause.fill` | 16 |
| Reset | `arrow.counterclockwise` | 13 |
| Skip | `forward.end.fill` | 13 |
| Work phase | `timer` | 14 live / 16 expanded |
| Short Break | `cup.and.saucer.fill` | same |
| Long Break | `moon.zzz.fill` | same |
| Back from note | `chevron.left` | 11 |
| Row disclosure | `chevron.right`, `textTertiary` | 10 |
| Edit in Notes | `square.and.pencil` | 11 |
| Folder pull-down chevron | `chevron.down` | 8 |
| Empty folder | `tray` | 24, `textTertiary` |
| Folder missing | `folder.badge.questionmark` | 24, `warning` |
| Permission needed | `lock.shield` | 24, `textSecondary` |
| Error | `exclamationmark.triangle.fill` | 24, `warning` |
| Menu bar extra | `rectangle.topthird.inset.filled` (template) | system |

Use `.symbolRenderingMode(.monochrome)`. Never mix filled and outline variants within one control group.

## 5. Layout wireframes

Notation: `▓` = island (black); `[ ]` = button; `( )` = icon-only button; notch zone shown as `░░░░░`.

### 5.1 Collapsed (idle)
```
screen top edge ─────────────────────────────────────────────
                    ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
                    ▓  hardware notch ▓      size = notchW x notchH, nothing drawn
                     ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
```
Indistinguishable from the bare notch.

### 5.2 Live activity (collapsed + running)
```
          ◄── 52 ──►◄──── notchW ────►◄── 52 ──►
         ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓
        ▓   🍅        hardware notch        24:59 ▓
         ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
          ↑ glyph 14pt, 10 outer pad           ↑ timeCompact, 10 outer pad
```
- Left: the phase glyph alone (14 pt, `accent`, vertically centered). No ring or outline in the wings; progress is shown only by the large ring in the expanded pane.
- Right: remaining time, `textPrimary`.
- **Paused:** the same glyph at 50% opacity and the time turns `textSecondary`. State differs by tone and the frozen countdown, not color alone.
- Both wings share one click/hover target. Click expands (sticky, see 7).

### 5.3 Expanded: inline Notes (left) + Pomodoro (right), 680 x 210
```
┌ ear 14 ─────────────────────────────────────────────────────────────────────────────────────┐
│  ▤ Notes  MacNotch ⌄      ↗ ░░░░░░░░░░░░ notch 190 ░░░░░░░░░░░░   🍅 Focus                    │ 34 band
│                                                                                              │  6
│  ┌ Groceries for Friday ────────── 2 hr ago ┐         ╭────────╮   ○ ○ ○ ○                   │
│  │ Oat milk, eggs, the good coffee…         │         │ 24:59  │   Session 1 of 4             │
│  │ Call plumber ────────────────── Yesterday│         │Remaining│   ( ⏸ ) ( ↺ )               │ 154 panes
│  │ Mon after 9. Ask about the kitchen…      │         ╰────────╯   [ ⏭ Next: Short Break ]   │
│  │ Reading list ────────────────── Mon      │          ring 112                            │
│  └ …  (4 rows visible, scrolls, soft fade) ─┘      <── 24 pt gap, no divider ──>             │
│                                                                                              │ 16
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```
- Notes list: up to 50 rows, `ScrollView` + `LazyVStack`, newest first. Row 38 pt, radius 8: title (`rowTitle`) and relative date (`meta`, tertiary) on the first line, snippet (`snippet`, secondary) on the second, tail-truncated. Hover `fillHover`; keyboard-highlighted `fillSelected`. A soft bottom fade appears only when more than 4 rows exist. `lists-and-tables.md › Best practices` (succinct text, title opens detail). The "Open Notes" icon sits in the band wing.
- Pomodoro pane: see 5.5.

### 5.4 Note detail (inline, inside the Notes pane; editable)
```
│  ▤ Notes                                 ░░ notch ░░    🍅 Focus
│  ‹  Groceries for Friday      Saved   [✎ Edit in Notes]
│  Oat milk▌
│  Eggs                                  (editor scrolls)  (Pomodoro pane unchanged)
```
- Selecting a row slides the detail in from the right (24 pt + fade, 0.22 s) while the list moves 24 pt left and fades; back reverses. The Pomodoro pane never moves. Reduce Motion: crossfade.
- Header: `chevron.left` back (label "Back to Notes"), live title (first line of the text), save status, and **Edit in Notes** (`square.and.pencil` + label, min 28 pt hit target). The band no longer shows "Open in Notes" in detail.
- Body is a rich-text editor (`NSTextView`, `isRichText`: system 12 (`Typo.noteBodySize`), white on black, white insertion point, no smart quotes/dashes, no spell squiggles, undo on, no font panel, no graphics). Titles/headings show at 17/15 pt semibold, code in monospace 11.5 pt, line spacing 1.5 pt, attachment chips 11 pt (all tokens in `Typo` in `UI/DesignTokens.swift`; the read-only text uses the same body size; saved HTML sizes 24/18/13 px are unchanged), links light blue underlined. It does not take focus on open (Space still toggles the timer while reading); clicking into it makes the panel key and the island sticky, so it cannot close on mouse-leave while editing. Display colors never reach Notes: default text color and font are never written.
- **Focus while editing (Notes-backed mode):** AppleScript `show` brings Notes frontmost, so every `show` is followed immediately by putting the previously frontmost app back (read live via the Accessibility system-wide focused app, restored with `AXFrontmost`; `NSRunningApplication.activate` is cooperative on macOS 14+ and is ignored when MacNotch is not active) and re-hiding Notes if it was hidden. `show` runs once at begin and again only when Notes has navigated to another note. Notes and MacNotch never count as the "previous app" (`FocusTracker`). Collapsing returns focus to the previous app; clicking another app just takes focus (resignKey saves, no re-activation). Notes is launched with `activates = false, hides = true, addsToRecentItems = false`. Log category `ax-edit` records the frontmost app at each step.
- **HTML editing only when provably lossless:** unlocked, no attachments, at most 60,000 characters, and the body HTML uses only: `div`/`p`, a trailing `br`, `b`/`strong`, `i`/`em`, `u`, `strike`/`s`, `tt`, `h1`–`h3`, `a href`, `font face` (system / Courier names Notes emits), `span style` limited to `font-size` 24/18/13 px (Title / Heading / body), `font-weight`, `font-style`, `text-decoration`, and plain `ul`/`ol` > `li` (no class). The decoded text must equal Notes' `plaintext`, and a round trip (parse, serialize, parse) must reproduce the same text and formatting. **Not HTML-safe** (edited through Notes instead, see *Notes-backed editing* below): attachments, `img`/`object`/`table`, checklists and other list classes (`Apple-dash-list`, …), nested lists, `blockquote`/`pre`/`code`, colors, soft line breaks, any unknown tag or attribute. Too long (read-only): `This note is too long to edit here — edit it in Notes.`; locked (always read-only): `This note is locked — edit it in Notes.`
- **Formatting:** ⌘B bold, ⌘I italic, ⌘U underline, ⇧⌘X strikethrough (on the selection, or for the next typed text; ⌘B on a title/heading turns it back into body text). Bullet and numbered lists continue on Return, an empty item (or Backspace at the start of an item) ends the list; markers are display-only and never saved as text. Return after a title starts body text. Paste keeps only bold/italic/underline/strike/monospace/links (no foreign fonts, colors or images); ⌥⇧⌘V pastes plain text; drops accept plain text only. Saved as Notes-style HTML: `<div>` per paragraph (`<div><br></div>` when empty), `<b>`, `<i>`, `<u>`, `<strike>`, `<tt>`, `<a href>`, titles/headings as Notes writes them (`<b><font face=".AppleSystemUIFontBold"><span style="font-size: 24px">` / 18 px), `<ul><li>` / `<ol><li>`. Text is escaped; runs of spaces are written as `&nbsp;`.
- **Keys while the text view has focus:** Esc (save, then back), ⌘S (save now) and the formatting shortcuts above. Space, Return, arrows, ⌘R, ⌘→ etc. go to the text. Standard ⌘X/C/V/A/Z/⇧⌘Z are handled by the editor (the panel has no Edit menu).
- **Saving:** autosave 1.5 s after typing stops, on Esc/back, on island collapse and at app quit. Status text in the header (`meta`): `Saving…`, then `Saved` (fades after 1.5 s), or `Not saved` (warning colour, never colour alone). The save writes the whole `body` as `<div>` lines (`&`, `<`, `>` escaped; empty line `<div><br></div>`; first line keeps its original wrapper) and then refreshes the list.
- **Conflict:** the note's modification date is captured when editing begins and re-checked inside the same script that writes. If it changed, nothing is written and an inline notice shows `Changed in Notes` with **Reload** (discard local text, load Notes' version) and **Keep Editing** (keep local text; the next save overwrites the newer version). Failed saves show `Couldn’t save. Your changes are still here.` with **Try Again**. Leaving is blocked while a conflict or error is unresolved.
- **Revert to Original:** once something was edited in this session, an `arrow.uturn.backward` button (label "Revert to Original") appears in the header. It writes back the body HTML exactly as it was when the note was opened (kept in memory), with the same conflict check, then reloads the editor.
- **Notes-backed editing (Accessibility).** A note the HTML codec rejects for a content reason (attachments, tables, checklists, nested lists, unknown markup) but that is not locked and not too long is edited *inside Notes' own text view* through Accessibility, so images and formatting are never rewritten. Requires `AXIsProcessTrusted()`; without it the note stays read-only with the caption `Notes with images or rich formatting are edited through Notes, which needs Accessibility access.` and the button **Allow Accessibility to Edit** (the only place the prompt is requested; MacNotch then waits up to 2 minutes for the grant and opens the editor by itself).
  - *Baseline and display.* Opening the note runs `show` (no `activate`) and reads the AXValue of Notes' text area (attachments are U+FFFC). The note is accepted only if that text equals the note's `plaintext` (whitespace and U+FFFC insensitive) and Notes' `selection` is this note, and `AXSelectedText` is settable; otherwise read-only (`MacNotch couldn’t reach this note’s editor in Notes — edit it in Notes.`). The editor text is built FROM the AX string, so offsets are Notes' offsets. Styling (title / headings / bold…) is borrowed from the HTML only when the HTML decodes to exactly that text (image tags counted as U+FFFC); otherwise plain text. Each U+FFFC is a non-editable `photo` chip (SF Symbol, secondary color): edits that intersect a chip, or paste containing U+FFFC, are refused with a beep. ⌘B/⌘I/⌘U/⇧⌘X beep and rich paste is turned into plain text. A tertiary caption under the editor says `Text edits only — formatting and images are preserved in Notes.`
  - *Saving.* Debounce 3 s (1.5 s for HTML notes), plus Esc / collapse / quit. The editor text is diffed against the baseline (`NotesTextDiff`): both texts are split at U+FFFC (counts must match, else refuse), each piece is diffed with Myers on composed character sequences, edits are applied from the end of the note to the start. Per edit: set `AXSelectedTextRange`, read it back, check the selected text is what we expect to replace, set `AXSelectedText`, and re-read `AXValue` until it equals the expected intermediate string. A mismatch stops the save, rolls back to the baseline with the inverse diff, and shows `Couldn’t save — open in Notes to check. Your changes are still here.` After the last edit the AX text must equal the target, then AppleScript `count attachments` must be unchanged and `plaintext` must match. Only attribute writes are used, never keystrokes.
  - *Conflict.* Before writing, the AX text is re-read; if it differs from the baseline (our last write or the load) nothing is written and the usual `Changed in Notes` notice appears. **Reload** re-reads Notes; **Keep Editing** re-bases on Notes' current text so the next save overwrites it with ours. A restored draft based on older Notes text starts as a conflict.
  - *Focus.* Notes may come forward when it shows the note; afterwards the previously frontmost app is re-activated, Notes is hidden (only if it was hidden or inactive before) and the editor regains key status. Selecting the note changes which note Notes itself has selected.
  - *Revert to Original* applies the inverse diff (current Notes text back to the opening text) through the same path. All AX calls run on one background queue with 1 s messaging timeouts and bounded loops.
- **Edit in Notes:** saves pending text, shows the note by id and activates Notes, then (if Accessibility is allowed) sets the insertion point to the start of the line the caret was on (UTF-16 offset in the same text, title is line 1), retrying for about 1.2 s and only if Notes' text begins with our first line. Read-only notes just open. If Accessibility is off, the note opens without the cursor jump and, because Notes then takes focus and the island closes, the next detail view shows once: `Allow Accessibility to jump to the line` with **Open Settings** (the only place the system prompt is requested; also opens Privacy › Accessibility) and **Not Now**.
- Folder pull-down (band, list view only): `Notes  MacNotch ⌄` — a `Menu` with an inline `Picker` (checkmark on the current folder), populated lazily on first hover (cached 30 s; database when Full Disk Access is on, else AppleScript only while Notes runs). Choosing a folder saves the setting and reloads.

### 5.5 Pomodoro pane (right)
```
  ╭─────────╮    ○ ○ ● ○            dots: filled accent = done, outline = pending
  │  24:59  │    Session 2 of 4
  │Remaining│    ( ⏸ ) ( ↺ )          primary 40 circle (accent fill, black glyph) + Reset 28
  ╰─────────╯    [ ⏭ Next: Short Break ]   visible pill, always enabled
```
- Ring: single `CAShapeLayer` linear animation (`CAProgress`), 112 pt, 5 pt line, accent on 15% track. No per-second redraw.
- Time: running = `Text(timerInterval:)` (system-rendered); paused/idle = static text with `.contentTransition(.numericText(countsDown: true))` so changing a duration in Settings rolls the digits. Status line under it: Ready / Remaining / Paused (not colour alone).
- **Next** is a visible labelled button (`forward.end.fill` + "Next: <phase>", destination computed with `PomodoroEngine.nextPhase`), calling `engine.skip()` in idle, running and paused states. VoiceOver label "Skip to <phase>". `buttons.md` (clear labels over bare icons). Reset is the secondary icon button.
- Accent per phase (Focus coral, Short Break green, Long Break blue); only applied while active, otherwise neutral.


### 5.6 Empty and error states (centered in the Notes pane, no card, 6-8 pt vertical rhythm, fits 336 x 154)
```
        ( symbol 20pt )
        Title                      rowTitle, textPrimary
        Body, max 2 lines          snippet, textSecondary, max width 300
        [ Primary Button ]  [ Secondary ]
```
| State | Symbol | Title | Body | Buttons |
|---|---|---|---|---|
| Permission, before asking | `lock.shield` | Allow MacNotch to Read Notes | MacNotch shows notes from one folder in the notch. macOS will ask for your permission next. | **Continue** (single button, opens the system alert) |
| Automation denied | `lock.shield` | Notes Access Is Off | Turn on MacNotch under Privacy & Security › Automation to see your notes. | **Open System Settings** |
| Full Disk Access needed (only if the data layer reads the Notes database; see 9) | `lock.shield` | Full Disk Access Needed | MacNotch needs Full Disk Access to read your notes quickly. Turn it on, then reopen MacNotch. | **Open System Settings**, **Quit MacNotch** |
| Folder missing | `folder.badge.questionmark` | No “MacNotch” Folder in Notes | Create a folder with this name in Notes, or choose another name in Settings. | **Create “MacNotch” Folder**, **Open Settings…** |
| No notes | `tray` | No Notes Yet | Add a note to the “MacNotch” folder in Notes and it will appear here. | **Open Notes** |
| All locked | `tray` | Only Locked Notes Here | Locked notes stay private and are not shown. | **Open Notes** |
| Loading (shown only after 300 ms) | none | none | small `ProgressView` (16 pt), centered | none |
| Notes not responding (5 s timeout) | `exclamationmark.triangle.fill` | Notes Didn’t Respond | Make sure Notes is not showing a dialog, then try again. | **Try Again** |

The folder name in copy is always the live setting value. Buttons use title-case (macOS convention); body copy uses sentence case. "Create Folder" is the only action that writes to Notes and it is always user-initiated.

## 6. Motion

All motion is SwiftUI springs on shape/opacity/offset (Core Animation backed). No timers drive visuals, no `Canvas`, no per-frame work, no blur animation.

| Transition | Animation |
|---|---|
| Open (collapsed or live → expanded) | `.spring(response: 0.42, dampingFraction: 0.78)` on the shape (size, ears, radius). Slight overshoot, ~6%. |
| Close | `.spring(response: 0.32, dampingFraction: 0.92)`. No bounce on exit (`motion.md › Providing feedback`: brief and precise). |
| Content in (on open) | Starts when the shape is ~60% there: `.easeOut(0.2)` opacity 0→1, scale 0.96→1, delay 0.08 s |
| Content out (on close) | `.easeIn(0.1)` opacity →0 first, before the shape shrinks |
| Content entrance (on expand) | Band, Notes pane, Pomodoro pane each fade in and slide up 6 pt, `.easeOut(0.28)`, 0.08 s base delay + 0.04 s stagger. Reduce Motion: opacity only. |
| List ↔ detail | Horizontal push 24 pt + fade, `.easeOut(0.22)` inside the Notes pane; back reverses. |
| Button press | Spring scale 0.96 (`response 0.25, damping 0.7`); none under Reduce Motion. |
| Phase change (also via Next) | Ring view re-identified per phase: 0.3 s opacity crossfade, new accent, ring reset to 0. Phase title crossfades. |
| Idle duration change | `.numericText(countsDown: true)`, `.snappy(0.3)`. |
| Wings appear/disappear | Shape width spring `response 0.35, damping 0.85`; glyph/time fade in 0.15 s after |
| Running time | Updates in place each second. `Text(timerInterval:pauseTime:countsDown:)` in the compact wing so the system renders the countdown without an app redraw. Switch to a plain `Text` when paused. |
| Phase complete (**pulse**) | One shot: wings scale 1 → 1.06 → 1; in the expanded view the ring does a one-shot `keyframeAnimator` 1 → 1.05 → 1 (triggered by `pulseID`) (`.spring(response: 0.3, dampingFraction: 0.5)`), glyph `symbolEffect(.bounce, value: phaseID)`, optional sound. Max duration under 2 s (`live-activities.md › Adding transitions`). |
| Hover highlight | `.easeOut(0.12)` |

**Timing**
- Hover **open delay 0.15 s**, **close delay 0.4 s**. Cancel the pending close if the pointer re-enters the shape (or the panel) during the delay. These avoid flicker when sweeping across the top of the screen.
- Any user input during an animation interrupts it and retargets (`motion.md › Providing feedback`: let people cancel motion). Never block clicks until an animation finishes.

**Reduce Motion** (`accessibilityReduceMotion`) (`accessibility.md › Cognitive`: replace transitions with fades, tighten springs, avoid scaling):
- Open/close become a **crossfade** between the collapsed layer and the fully-sized expanded layer, `.easeInOut(0.15)`. No size spring, no scale.
- Phase pulse: no scaling or bounce; the glyph swaps with a 0.15 s crossfade and the time changes to the next phase value. The sound (if enabled) is the cue.
- List ↔ detail: crossfade, no push.

**Idle budget.** Collapsed and idle: 0 timers, 0 observers beyond a mouse-move tracking area on the hover rect (`NSTrackingArea`, not global monitors), 0 layers animating. Notes are fetched on expand (async, cached 30 s), never polled. When a timer runs: one `Timer` firing each second aligned to the second boundary, `tolerance = 0.1`, computing remaining time from an end `Date` (survives sleep). Cancel it on pause or reset.

## 7. Interaction

**Open/close**
1. Pointer enters the hover rect (the shape's current bounds, extended up to the screen edge, plus 2 pt around) for 0.15 s → expand. **Hover-open does not activate the app or steal focus.**
2. Pointer leaves the expanded shape for 0.4 s → collapse. This applies only while the island is in *hover* mode.
3. **Sticky mode.** A click inside the island makes the panel key (`canBecomeKey = true`) and pins it open. It then closes only on click outside or Esc. Reading a note should not vanish when the pointer drifts.
4. Ignore hover while a mouse button is down (dragging windows near the top edge must not open the island).
5. Hide over full-screen apps only if the system hides the menu bar (default `.fullScreenAuxiliary` behavior); otherwise stay.

**Keyboard** (active only when the panel is key, i.e. in sticky mode; hover alone cannot receive keys without global monitoring and extra permissions, which we avoid)
| Key | Action |
|---|---|
| Space | Start/Pause timer (unless the note text view has focus) |
| Esc | Back from note detail; otherwise close the island |
| ⌘R | Reset timer |
| ⌘→ | Skip phase |
| ↑ ↓ / Return | Move through / open note rows |
| Tab | Standard focus order, with system focus rings |

Do not override system shortcuts (`accessibility.md › Speech`).

**Pointer states.** Default arrow everywhere (macOS lists do not use a pointing hand). Hover: `fillHover` on rows, tabs, and buttons. Pressed: `fillPressed`. Disabled: `textDisabled`. Tooltips (`.help`) on every icon-only control.

**Pomodoro behavior**
- Cycle: Focus 25 → Short Break 5, repeated 4 times, then Long Break 15 (all configurable).
- Reset returns to the start of the **current phase**. Skip jumps to the next phase, idle (not auto-started). A completed phase also lands idle on the next phase; it never auto-starts (agency, `design-principles.md › Agency`). After 10 minutes idle in that state, the wings go away and the timer is cleared to the beginning of a new Focus phase (judgment).
- Skip during a running Focus does not count the session.

## 8. Accessibility

**No tabs.** Both sections are visible at once, so there is no switching control. Section titles ("Notes", phase name) sit in the band wings beside the hardware notch (`layout.md › Desktop (macOS)`: keep the notch zone clear).

**Labels and traits** (every icon-only control)
| Control | `accessibilityLabel` | Notes |
|---|---|---|
| Open Notes (band icon) | "Open Notes" | |
| Start/Pause | "Start Timer" / "Pause Timer" | value: "Focus, 24 minutes 59 seconds remaining" |
| Reset | "Reset Timer" | hint "Returns to the start of this phase" |
| Next | "Skip to Short Break" (dynamic) | visible text "Next: Short Break"; hint "Ends this phase and moves to the next one" |
| Back (in detail) | "Back to Notes" | |
| Edit in Notes | "Edit in Notes" | hint "Opens this note in the Notes app at the line you are editing" |
| Folder pull-down | "Folder: MacNotch" | hint "Choose which Notes folder to show" |
| Note editor | "Note text" | hint "Edit the note. Changes save automatically." |
| Note row | "\(title). \(snippet)" | hint "Shows the full note"; trait `isButton` |
| Collapsed live wings (single element) | "Focus timer, 24 minutes 59 seconds remaining, running" | hint "Opens MacNotch"; custom action "Pause Timer" |
| Session dots | one element: "Session 2 of 4" | hide the dots individually |

**VoiceOver order** (declare with `accessibilitySortPriority`; container is `accessibilityElement(children: .contain)` labelled "MacNotch"): Notes (visual left) then Pomodoro (visual right): Notes title → Folder menu → Open Notes → rows, or back + Edit in Notes + body → Pomodoro title → time → Start/Pause → Reset → Next → sessions. Hover cannot be performed with VoiceOver, so the collapsed element's default action expands the island in sticky mode, and the menu bar extra has "Show Panel". Do not announce each second. Post `AccessibilityNotification.Announcement` only on phase change ("Focus complete. Short Break is ready.").

**Other.** Colors and contrast per section 3. Controls at least 28 pt. Keyboard-only use is fully supported once the panel is key (section 7). The pulse is redundant with sound, text, and the changed time (`feedback.md › Best practices`: more than one channel). Optional trackpad haptic: `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)` on phase completion.

## 9. Permissions UX

Request nothing at launch (`privacy.md › Requesting permission`: ask when the feature is used). MacNotch with no Notes access works fully as a Pomodoro timer.

1. **Automation for Notes (required).** The first time the island expands, show the "Allow MacNotch to Read Notes" pre-alert state (5.6). It has exactly one button, "Continue", which triggers the system alert by sending a harmless Apple Event (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: true`). No Cancel button and no "Allow"-style wording in our button (`privacy.md › Pre-alert screens, windows, or views`). If the user denies, show "Notes Access Is Off" with a button to `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`. Re-check status each time the island expands (cheap) so granting in System Settings takes effect without a relaunch.
2. **Full Disk Access (avoid).** Recommended v1 data path is Apple Events (`tell application "Notes"`), which needs only Automation and handles locked notes (`password protected` property) without parsing the database. Request Full Disk Access **only** if engineering chooses to read the Notes SQLite store for speed; in that case show the FDA state (5.6) when the first read fails with a permission error. It opens `…?Privacy_AllFiles` and tells the user to reopen the app because macOS applies it only after relaunch. Asking for FDA when Automation suffices breaks "request only the data you need" (`privacy.md › Best practices`).
3. **Scope.** Read only: the configured folder, note id, title, plain-text body, modification date, and the password-protected flag. Never read locked-note bodies. Nothing is written except the explicit "Create Folder" action, the "Open in Notes" (show) action, and the body of an unlocked note whose formatting MacNotch can save losslessly the user edited in the inline editor (see 5.4 for the safeguards: conflict check, no attachments/rich content, locked re-check). No analytics, no network.
5. **Accessibility (optional: "Edit in Notes" cursor placement and editing notes with images / rich formatting).** Never requested at launch or on first use of the button. When the user clicks **Open Settings** on the in-notch hint, call `AXIsProcessTrustedWithOptions` with the prompt and open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. Purpose, stated plainly: MacNotch moves the text cursor in the Notes window to the line you were editing; it does not read anything else. For notes with images, tables, checklists or other rich content, MacNotch also reads the note's text area and applies your text edits there as attribute writes (never keystrokes), only after you click **Allow Accessibility to Edit**; without it those notes stay read-only and everything else works.
4. **Info.plist.** `LSUIElement = YES` (no Dock icon). Use the hardened runtime with the Apple Events entitlement `com.apple.security.automation.apple-events`; if sandboxed, also `com.apple.security.temporary-exception.apple-events` for `com.apple.Notes`. Sign with Developer ID (`privacy.md › Desktop (macOS)`).

**Exact `NSAppleEventsUsageDescription`:**
```
MacNotch reads the titles and text of unlocked notes in the one Notes folder you choose, so it can show them in the notch. It changes a note only when you edit it in the notch, and sends nothing off your Mac.
```
(Active voice, specific, one purpose, per `privacy.md › Requesting permission`. Accurate wrt. editing: writes happen only after the user types in the inline editor; "Create Folder" is an explicit click.)

## 10. Menu bar extra and Settings

### 10.1 Menu bar extra
Use `MenuBarExtra` with the `.menu` style, not a popover (`the-menu-bar.md › Menu bar extras`: "Display a menu — not a popover"). Template icon `rectangle.topthird.inset.filled`.

```
 Start Timer          (title toggles: Pause Timer)
 Reset Timer
 ─────────────
 Show Panel
 ─────────────
 Settings…       ⌘,
 ─────────────
 Quit MacNotch   ⌘Q
```
- Menu items stay present and are disabled when not applicable (`the-menu-bar.md › Best practices`: always show the same set).
- A **"Show in Menu Bar"** toggle in Settings lets people hide it (`the-menu-bar.md › Menu bar extras`: people decide). If hidden, relaunching MacNotch opens Settings, so the app is never unreachable.
- Because the extra can be hidden by the system, Settings and basic controls are also reachable from the island (⌘, when the panel is key).

### 10.2 Settings window (`Settings { }` scene, ⌘,)
Single pane, titled **"MacNotch Settings"** (`settings.md › Desktop (macOS)`: single-pane title is *App Name* Settings). Minimize/zoom buttons dimmed, fixed width 420, height fits content. Controls apply immediately (no Apply button). Defaults must work without opening this window (`settings.md › Best practices`).
```
┌ MacNotch Settings ──────────────────────────────────────┐
│ General                                                   │
│   [✓] Launch at Login                                     │
│   [✓] Show in Menu Bar                                    │
│   [ ] Show Timer Next to Notch While Running              │
│   Panel Width   360 ──────●──── 520        420 pt         │
│   Panel Height  160 ──●──────── 240        180 pt         │
│                                                           │
│ Notes                                                     │
│   Folder        [ MacNotch              ⌃ ]  (pop-up)     │
│                 Other… → Folder Name [        ]           │
│   ✓ Found · 12 unlocked notes, 2 locked hidden            │
│   (or ⚠ No folder with this name in Notes)                │
│                                                           │
│ Pomodoro                                                  │
│   Focus            [ 25 ] min   (1–90)                    │
│   Short Break      [  5 ] min   (1–30)                    │
│   Long Break       [ 15 ] min   (1–60)                    │
│   Long Break After [  4 ] focus sessions                  │
│   [✓] Play Sound When a Phase Ends                        │
└──────────────────────────────────────────────────────────┘
```
- "Show Timer Next to Notch While Running" is `@AppStorage("ui.showTimerWhileCollapsed")`, default off; the window agent reads the same key for the collapsed wings.
- Launch at Login uses `SMAppService.mainApp`. Sound uses the system "Glass" sound and follows the system alert volume.
- Folder is a pop-up button (`pop-up-buttons.md`) listing the folders found in Notes (unique names, no Recently Deleted), loaded when Settings opens, plus **Other…** which reveals a text field (500 ms debounce) for a folder that does not exist yet; when the folder is missing, **Create “Name” Folder** appears (explicit click). With no folder list available (Notes closed, no access) the text field is shown directly. The status line is a text status, not a color-only cue.
- Duration changes during a running phase apply to the next phase; do not alter the running one.
- Not included on purpose: appearance/theme, hover delays, accent colors, auto-start (`settings.md › Best practices`: minimize settings; respect system settings).

## 11. Do not
- Do not draw anything in the hardware notch zone, or let content sit behind it.
- Do not use blur, materials, Liquid Glass, gradients, or a drop shadow in the collapsed state. The island is `#000000`.
- Do not animate anything at idle: no breathing glow, no looping ring, no shimmer.
- Do not use `Timer` at sub-second intervals, `TimelineView(.animation)`, or `Canvas` redraw loops.
- Do not poll Notes. Fetch on expand; cache 30 s.
- Do not request Automation, Full Disk Access, notifications, or accessibility permissions at launch, and do not request Accessibility permission to catch global keys.
- Do not read, show, or log the bodies of locked notes.
- Do not auto-start the next Pomodoro phase or auto-dismiss the island on a timer while the user is reading.
- Do not communicate phase by color alone, and do not use the user's macOS accent color for phase meaning.
- Do not add an app-specific light/dark setting (`dark-mode.md › Best practices`).
- Do not use Title Case for body copy or sentence case for buttons (buttons: Title Case; body: sentence case).
- Do not add features beyond Notes and Pomodoro (no search, tags, multi-folder, stats) without revisiting the restraint rules.
