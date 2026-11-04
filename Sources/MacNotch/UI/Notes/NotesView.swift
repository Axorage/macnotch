import SwiftUI
import AppKit
import ApplicationServices

/// Wing title for the Notes pane (left of the notch): title, folder pull-down, then the Notes shortcut.
struct NotesBand: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var notes: NotesProvider
    @Environment(\.palette) private var palette

    var body: some View {
        let detail = viewModel.selectedNote != nil
        HStack(spacing: Space.s) {
            Image(systemName: "note.text").font(Typo.symbol(13)).foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            Text("Notes").font(Typo.tab).foregroundStyle(palette.textPrimary).lineLimit(1)
                .layoutPriority(1)
            if !detail { FolderMenu(notes: notes) }
            Spacer(minLength: 0)
            if !detail, notes.status == .ok {
                IconButton(symbol: "arrow.up.forward.app", size: 12, label: "Open Notes",
                           hint: "Opens the Notes app") { openNotesApp() }
                    .transition(.opacity)
            }
        }
        .padding(.leading, Space.xs)
        .animation(Motion.fade, value: detail)
        .accessibilityElement(children: .contain)
    }
}

/// Compact pull-down that names the folder being shown and lets the user switch it
/// (`pull-down-buttons.md`: a menu of actions/choices; checkmark marks the current one).
private struct FolderMenu: View {
    @ObservedObject var notes: NotesProvider
    @Environment(\.palette) private var palette

    private var folders: [String] {
        var list = notes.availableFolders
        if !list.contains(where: { $0.caseInsensitiveCompare(notes.folderName) == .orderedSame }) {
            list.insert(notes.folderName, at: 0)
        }
        return list
    }

    var body: some View {
        Menu {
            Picker("Folder", selection: Binding(get: { notes.folderName }, set: { notes.folderName = $0 })) {
                ForEach(folders, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(notes.folderName).font(Typo.meta).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(palette.textSecondary)
            .frame(minHeight: Metrics.minHit)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 110)
        .onHover { if $0 { notes.loadFolders() } }
        .help("Choose which Notes folder to show")
        .accessibilityLabel("Folder: \(notes.folderName)")
        .accessibilityHint("Choose which Notes folder to show")
    }
}

/// Left pane: list of notes, or inline detail, or a compact state.
struct NotesPane: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var notes: NotesProvider
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotesContent(notes: notes, viewModel: viewModel, reduceMotion: reduceMotion)
            .onAppear { appState.notes.refreshIfNeeded() }
    }
}

private struct NotesContent: View {
    @ObservedObject var notes: NotesProvider
    @ObservedObject var viewModel: NotchViewModel
    let reduceMotion: Bool
    @EnvironmentObject private var appState: AppState
    @State private var showLoading = false
    @State private var asked = UserDefaults.standard.bool(forKey: "notes.automationAsked")

    var body: some View {
        Group { content }
            .onChange(of: notes.status) { _, st in
                if st != .ok, st != .loading, viewModel.selectedNote != nil { viewModel.leaveNote() }
            }
    }

    /// The list with the open note's detail on top.
    @ViewBuilder private var notesStack: some View {
            ZStack(alignment: .top) {
                NotesList(notes: notes.notes, viewModel: viewModel)
                    .offset(x: viewModel.selectedNote != nil && !reduceMotion ? -24 : 0)
                    .opacity(viewModel.selectedNote == nil ? 1 : 0)
                    .allowsHitTesting(viewModel.selectedNote == nil)
                    .accessibilityHidden(viewModel.selectedNote != nil)
                if let note = viewModel.selectedNote {
                    NoteDetail(note: note, notes: notes, viewModel: viewModel) { viewModel.closeNote() }
                        .id(note.id)
                        .transition(viewModel.restoring ? .identity
                                    : (reduceMotion ? .opacity : .offset(x: 24).combined(with: .opacity)))
                }
            }
            .animation(viewModel.restoring ? nil : (reduceMotion ? Motion.fade : Motion.push), value: viewModel.selectedNote)
            .onChange(of: notes.notes) { _, list in
                if let sel = viewModel.selectedNote, !list.isEmpty, !list.contains(where: { $0.id == sel.id }) { viewModel.closeNote() }
            }
    }

    @ViewBuilder private var content: some View {
        switch notes.status {
        // One branch for both so a restored note keeps its view identity while the list is still loading.
        case .ok, .loading:
            if notes.status == .ok || viewModel.selectedNote != nil {
                notesStack
            } else {
                ZStack {
                    if showLoading { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    showLoading = true
                }
                .onDisappear { showLoading = false }
            }
        case .needsAutomationAccess:
            if asked {
                StateView(symbol: "lock.shield", title: "Notes Access Is Off",
                          message: "Turn on MacNotch under Privacy & Security › Automation to see your notes.",
                          buttons: [("Open System Settings", { NotesProvider.openAutomationSettings() })])
            } else {
                StateView(symbol: "lock.shield", title: "Allow MacNotch to Read Notes",
                          message: "MacNotch shows notes from one folder in the notch. macOS will ask for your permission next.",
                          buttons: [("Continue", {
                              asked = true
                              UserDefaults.standard.set(true, forKey: "notes.automationAsked")
                              Task { await notes.requestAutomationAccess() }
                          })])
            }
        case .notesNotRunning:
            StateView(symbol: "note.text", title: "Open Notes to See Your Notes",
                      message: "MacNotch doesn\u{2019}t launch Notes on its own. Open it and your notes will appear here.",
                      buttons: [("Open Notes", { openNotesApp() })])
        case .needsFullDiskAccess:
            StateView(symbol: "lock.shield", title: "Full Disk Access Needed",
                      message: "MacNotch needs Full Disk Access to read your notes quickly. Turn it on, then reopen MacNotch.",
                      buttons: [("Open System Settings", { NotesProvider.openFullDiskAccessSettings() }),
                                ("Quit MacNotch", { NSApp.terminate(nil) })])
        case .folderNotFound(let name):
            StateView(symbol: "folder.badge.questionmark", symbolColor: Palette().warning,
                      title: "No “\(name)” Folder in Notes",
                      message: "Create a folder with this name in Notes, or choose another name in Settings.",
                      buttons: [("Create “\(name)” Folder", { Task { await notes.createFolder() } }),
                                ("Open Settings…", { appState.openSettings() })])
        case .empty:
            StateView(symbol: "tray", title: "No Notes Yet",
                      message: "Add a note to the “\(notes.folderName)” folder in Notes and it will appear here.",
                      buttons: [("Open Notes", { openNotesApp() })])
        case .error:
            StateView(symbol: "exclamationmark.triangle.fill", symbolColor: Palette().warning,
                      title: "Notes Didn’t Respond",
                      message: "Make sure Notes is not showing a dialog, then try again.",
                      buttons: [("Try Again", { notes.reload() })])
        }
    }
}

func openNotesApp() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct NotesList: View {
    let notes: [NoteItem]
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(notes.prefix(50)) { note in
                        NoteRow(note: note, highlighted: viewModel.highlightedRow == note.id) {
                            viewModel.openNote(note)
                        }
                        .id(note.id)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .mask(
                // Soft bottom edge only when more rows exist than fit.
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: notes.count > 4 ? 0.88 : 1),
                                       .init(color: notes.count > 4 ? .black.opacity(0.15) : .black, location: 1)],
                               startPoint: .top, endPoint: .bottom))
            .onChange(of: viewModel.highlightedRow) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    f.dateTimeStyle = .named
    return f
}()

private struct NoteRow: View {
    let note: NoteItem
    let highlighted: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let date = relativeFormatter.localizedString(for: note.modified, relativeTo: Date())
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(note.title).font(Typo.rowTitle).foregroundStyle(palette.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(note.snippet).font(Typo.snippet).foregroundStyle(palette.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Text(date).font(Typo.meta).foregroundStyle(palette.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, Space.s)
            .frame(height: Metrics.noteRowHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(highlighted ? palette.fillSelected : (hovering ? palette.fillHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(note.title). \(note.snippet). \(date)")
        .accessibilityHint("Shows the full note")
        .accessibilityAddTraits(.isButton)
    }
}

private struct NoteDetail: View {
    let note: NoteItem
    @ObservedObject var notes: NotesProvider
    @ObservedObject var viewModel: NotchViewModel
    let back: () -> Void
    @StateObject private var session: NoteEditSession
    @Environment(\.palette) private var palette
    @State private var text: String?
    @State private var axHint = false

    private static let limit = 4000

    init(note: NoteItem, notes: NotesProvider, viewModel: NotchViewModel, back: @escaping () -> Void) {
        self.note = note; self.notes = notes; self.viewModel = viewModel; self.back = back
        _session = StateObject(wrappedValue: NoteEditSession(note: note, notes: notes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            header
            banner
            bodyView
        }
        .task {
            axHint = Self.shouldShowAXHint
            await session.load()
            if let d = viewModel.drafts.removeValue(forKey: note.id) { session.restore(draft: d) }
            if session.mode != .editable { text = await notes.fullBody(for: note) }
        }
        .onDisappear {
            // Island collapsed or detail left: remember the caret, save, and keep any text that could not be saved.
            let id = note.id
            viewModel.rememberedCaret[id] = session.selection.location
            Task { @MainActor in
                let saved = await session.saveNow()
                Log.notes.notice("save: onDisappear saved=\(saved) state=\(String(describing: session.saveState), privacy: .public)")
                if !saved, let d = session.draft() { viewModel.drafts[id] = d }
            }
        }
    }

    private static var shouldShowAXHint: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: NotesProvider.axHintPendingKey) && !d.bool(forKey: NotesProvider.axHintDismissedKey)
            && !AXIsProcessTrusted()
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: Space.xs) {
            IconButton(symbol: "chevron.left", size: 12, label: "Back to Notes",
                       hint: session.hasUnsavedChanges ? "Saves your changes and returns to the list" : "Returns to the list") {
                Task { if await session.finish() { back() } }
            }
            Text(session.liveTitle).font(Typo.rowTitle).foregroundStyle(palette.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            status
            if session.hasEdited, session.mode == .editable {
                IconButton(symbol: "arrow.uturn.backward", size: 12, label: "Revert to Original",
                           hint: "Puts the note back the way it was when you opened it") {
                    session.revertToOriginal()
                }
                .help("Revert to Original")
            }
            HoverButton(radius: 7, action: {
                Task { if await session.editInNotes() { viewModel.collapse() } }
            }) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "square.and.pencil").font(Typo.symbol(11))
                    Text("Edit in Notes").font(Typo.tab).lineLimit(1)
                }
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, Space.s)
                .frame(minHeight: Metrics.minHit)
            }
            .help("Edit in Notes")
            .accessibilityLabel("Edit in Notes")
            .accessibilityHint("Opens this note in the Notes app at the line you are editing")
        }
    }

    @ViewBuilder private var status: some View {
        Group {
            switch session.saveState {
            case .saving: Text("Saving\u{2026}").foregroundStyle(palette.textTertiary)
            case .saved: Text("Saved").foregroundStyle(palette.textTertiary)
            case .failed: Text("Not saved").foregroundStyle(palette.warning)
            default: EmptyView()
            }
        }
        .font(Typo.meta)
        .lineLimit(1)
        .transition(.opacity)
        .animation(Motion.fade, value: session.saveState)
        .accessibilityElement(children: .combine)
    }

    // MARK: inline states

    @ViewBuilder private var banner: some View {
        if session.saveState == .conflict {
            InlineNotice(symbol: "exclamationmark.triangle.fill", text: "Changed in Notes",
                         actions: [("Reload", { session.reloadFromNotes() }),
                                   ("Keep Editing", { session.keepEditing() })])
        } else if case .failed(let message) = session.saveState {
            InlineNotice(symbol: "exclamationmark.triangle.fill", text: "\(message) Your changes are still here.",
                         actions: [("Try Again", { session.retry() })])
        } else if session.mode == .readOnly(.needsAccessibility) {
            InlineNotice(symbol: "hand.raised", text: "Editing this note needs Accessibility",
                         actions: [("Allow Accessibility to Edit", { session.requestAccessibilityAndWait() })])
        } else if axHint, session.mode != .readOnly(.needsAccessibility) {
            InlineNotice(symbol: "hand.raised", text: "Allow Accessibility to jump to the line",
                         actions: [("Open Settings", { NotesProvider.requestAccessibility(); axHint = false }),
                                   ("Not Now", {
                                       UserDefaults.standard.set(true, forKey: NotesProvider.axHintDismissedKey)
                                       axHint = false })])
        }
    }

    @ViewBuilder private var bodyView: some View {
        switch session.mode {
        case .editable:
            NoteTextEditor(session: session, onEscape: {
                _ = viewModel.handleKey(keyCode: 53, command: false, textFocused: true)
            }, autoFocus: viewModel.focusEditorOnOpen, initialCaret: viewModel.rememberedCaret[note.id] ?? 0)
            .accessibilityHint("Edit the note. Changes save automatically.")
            if session.backing == .accessibility {
                Text("Text edits only \u{2014} formatting and images are preserved in Notes.")
                    .font(Typo.meta).foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, Space.s)
            }
        case .readOnly(let reason):
            VStack(alignment: .leading, spacing: Space.xs) {
                readOnlyText
                Text(Self.caption(reason)).font(Typo.meta).foregroundStyle(palette.textTertiary)
                    .padding(.horizontal, Space.s)
            }
        case .loading, .unavailable:
            readOnlyText
        }
    }

    private static func caption(_ r: NoteEditSession.ReadOnlyReason) -> String {
        switch r {
        case .rich: return "This note changed in a way MacNotch can\u{2019}t save safely \u{2014} edit it in Notes."
        case .needsAccessibility: return "This note is edited through Notes itself so its images and formatting stay intact. That needs Accessibility access."
        case .axUnavailable: return "MacNotch couldn\u{2019}t reach this note in Notes just now \u{2014} reopen it, or edit it in Notes."
        case .tooLong: return "This note is over 200,000 characters \u{2014} edit it in Notes."
        case .locked: return "This note is locked \u{2014} edit it in Notes."
        }
    }

    private var readOnlyText: some View {
        let full = session.readOnlyDisplay ?? text ?? note.snippet
        let truncated = full.count > Self.limit
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(truncated ? String(full.prefix(Self.limit)) : full)
                    .font(Typo.noteBody).lineSpacing(Typo.noteLineSpacing)
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncated {
                    Text("Open in Notes to read the rest.").font(Typo.meta).foregroundStyle(palette.textTertiary)
                }
            }
            .padding(.horizontal, Space.s)
        }
    }
}

/// One-line inline message with text buttons (no modal; `feedback.md`: keep it in context, say what to do).
private struct InlineNotice: View {
    let symbol: String
    let text: String
    let actions: [(String, () -> Void)]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(Typo.symbol(11)).foregroundStyle(palette.warning)
                .accessibilityHidden(true)
            Text(text).font(Typo.meta).foregroundStyle(palette.textSecondary).lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            ForEach(actions.indices, id: \.self) { i in
                HoverButton(radius: 6, action: actions[i].1) {
                    Text(actions[i].0).font(Typo.meta.weight(.semibold)).foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, Space.s).frame(minHeight: 22)
                }
            }
        }
        .padding(.horizontal, Space.s)
        .accessibilityElement(children: .contain)
    }
}
