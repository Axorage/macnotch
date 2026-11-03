import SwiftUI

/// Inline expanded content: Notes (left) and Pomodoro (right), no tabs.
/// Top band (notch height) holds pane titles in the wings beside the hardware notch;
/// the centre of the band stays empty. See docs/DESIGN.md section 2.4.
///
/// `ExpandedView()` reads `NotchViewModel` from the environment; `ExpandedView(viewModel:)`
/// remains as a compatibility initializer for the current NotchRootView.
struct ExpandedView: View {
    private let injected: NotchViewModel?

    init(viewModel: NotchViewModel? = nil) { injected = viewModel }

    var body: some View {
        if let injected { ExpandedContent(viewModel: injected) } else { EnvironmentExpanded() }
    }
}

private struct EnvironmentExpanded: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    var body: some View { ExpandedContent(viewModel: viewModel) }
}

private struct ExpandedContent: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var appState: AppState
    @State private var shown = false

    private var contentWidth: CGFloat { viewModel.expandedBody.width - Space.xl * 2 }
    private var wingWidth: CGFloat {
        max(0, (contentWidth - viewModel.notchSize.width - Metrics.notchClearance * 2) / 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Band: [notes title | notch | phase title]
            HStack(spacing: 0) {
                NotesBand(viewModel: viewModel, notes: appState.notes)
                    .frame(width: wingWidth)
                Spacer(minLength: 0)
                PomodoroBand(engine: appState.pomodoro)
                    .frame(width: wingWidth, alignment: .leading)
            }
            .frame(height: viewModel.headerHeight)
            .entrance(0, shown: shown)

            Spacer().frame(height: Metrics.bandGap)

            HStack(alignment: .top, spacing: Metrics.paneGap) {
                NotesPane(viewModel: viewModel, notes: appState.notes)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .entrance(1, shown: shown)
                PomodoroPane(engine: appState.pomodoro, pulseID: viewModel.pulseID)
                    .frame(width: Metrics.pomodoroPaneWidth)
                    .frame(maxHeight: .infinity)
                    .entrance(2, shown: shown)
            }
            .accessibilityElement(children: .contain)
            .padding(.bottom, Metrics.paneBottom)
        }
        .padding(.horizontal, Metrics.expandedEar + Space.xl)
        .onAppear { shown = true }
        .onDisappear { shown = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacNotch")
    }
}
