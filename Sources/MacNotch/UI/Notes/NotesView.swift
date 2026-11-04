import SwiftUI
import AppKit

/// Wing title for the Notes pane, laid out like the Pomodoro band and centred in the wing: Notes icon, the
/// current folder name and a small chevron. The name is the folder selector (borderless pull-down menu).
struct NotesBand: View {
    @ObservedObject var notes: NotesProvider
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var folders: [String] {
        var list = notes.availableFolders
        if !list.contains(where: { $0.caseInsensitiveCompare(notes.folderName) == .orderedSame }) {
            list.insert(notes.folderName, at: 0)
        }
        return list
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Spacer(minLength: 0)
            Image(systemName: "note.text").font(Typo.symbol(14)).foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            Menu {
                Picker("Folder", selection: Binding(get: { notes.folderName }, set: { notes.folderName = $0 })) {
                    ForEach(folders, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text(notes.folderName).font(Typo.tab).foregroundStyle(palette.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: Metrics.minHit)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? palette.fillHover : .clear))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { h in
                withAnimation(Motion.hover) { hovering = h }
                if h { notes.loadFolders() }
            }
            .accessibilityLabel("Notes folder: \(notes.folderName)")
            .accessibilityHint("Choose which Notes folder to show")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Left pane: the folder's notes (click opens in Notes), or a compact state.
struct NotesPane: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var notes: NotesProvider
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NotesContent(notes: notes, viewModel: viewModel)
            .onAppear { appState.notes.refreshIfNeeded() }
    }
}

private struct NotesContent: View {
    @ObservedObject var notes: NotesProvider
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var appState: AppState
    @State private var showLoading = false
    @State private var asked = UserDefaults.standard.bool(forKey: "notes.automationAsked")

    var body: some View { content }

    @ViewBuilder private var content: some View {
        switch notes.status {
        case .ok, .loading:
            if notes.status == .ok {
                NotesList(notes: notes.notes, viewModel: viewModel) { viewModel.openNote($0) }
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
        case .folderNotFound(let name):
            StateView(symbol: "folder.badge.questionmark", symbolColor: Palette().warning,
                      title: "No “\(name)” Folder in Notes",
                      message: "Create it here, or choose another folder from the menu above.",
                      buttons: [("Create “\(name)” Folder", { Task { await notes.createFolder() } })])
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
    let open: (NoteItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(notes) { note in
                        NoteRow(note: note, highlighted: viewModel.highlightedRow == note.id) {
                            open(note)
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
        .accessibilityHint("Opens the note in Notes")
        .accessibilityAddTraits(.isButton)
    }
}
