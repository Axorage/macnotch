import SwiftUI
import AppKit

/// Settings › Permissions. Each row shows a live, silently-checked status and one action:
/// "Request Access" (shows the real system prompt, which is what lists MacNotch in Privacy & Security)
/// or "Open Settings" (deep link). Statuses refresh whenever the app becomes active.
struct PermissionsSection: View {
    @EnvironmentObject private var appState: AppState

    private enum Status { case granted, notGranted, notRequested
        var label: String {
            switch self { case .granted: "Granted"; case .notGranted: "Not Granted"; case .notRequested: "Not Requested" }
        }
        var symbol: String {
            switch self { case .granted: "checkmark.circle.fill"; case .notGranted: "xmark.circle.fill"; case .notRequested: "circle.dashed" }
        }
        var color: Color {
            switch self { case .granted: .green; case .notGranted: .red; case .notRequested: .secondary }
        }
    }

    @State private var automation: Status = .notRequested

    var body: some View {
        Section {
            row("Notes (Automation)", "Needed to list the notes in your folder and open one in Notes.", automation) {
                if automation == .notRequested {
                    Button("Request Access") {
                        Task { await appState.notes.requestAutomationAccess(); await refresh() }
                    }
                } else if automation == .notGranted {
                    Button("Open Settings") { NotesProvider.openAutomationSettings() }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("MacNotch appears under Privacy & Security only after it asks. Everything stays on your Mac.")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.systempreferences" { Task { await refresh() } }
        }
    }

    private func row<A: View>(_ title: String, _ detail: String, _ status: Status,
                              @ViewBuilder actions: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Label(status.label, systemImage: status.symbol)
                    .foregroundStyle(status.color)
                    .accessibilityLabel("\(title): \(status.label)")
            } label: {
                Text(title)
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            HStack { actions() }.controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func refresh() async {
        let ae = await Task.detached(priority: .utility) { NotesProvider.automationStatusSilently() }.value
        automation = ae == true ? .granted : (ae == false ? .notGranted : .notRequested)
    }
}
