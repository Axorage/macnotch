import SwiftUI

enum ContentPhase { case before, shown, after }

/// Drives the Dynamic-Island-style choreography with a tiny state machine
/// (hidden -> growing -> expanded -> shrinking -> hidden). Every step is a plain state change inside its own
/// `withAnimation`, so SwiftUI springs retarget from the current value when the pointer comes back mid-flight.
/// Delayed steps are cancellable work items; nothing runs when idle.
@MainActor
final class IslandPresenter: ObservableObject {
    @Published private(set) var shape: IslandLayout
    @Published private(set) var visible: Bool
    @Published private(set) var wingsMounted: Bool
    @Published private(set) var wingsShown: Bool
    @Published private(set) var expandedMounted: Bool
    @Published private(set) var expandedPhase: ContentPhase

    var reduceMotion = false
    private var target: IslandLayout
    private var work: [DispatchWorkItem] = []

    static let openSpring = Motion.openSpring
    static let wingsSpring = Motion.wingsSpring
    static let closeSpring = Motion.closeSpring
    static let reducedEase = Motion.reducedEase

    init(initial: IslandLayout) {
        target = initial
        shape = initial
        visible = initial != .hidden
        wingsMounted = initial == .live
        wingsShown = initial == .live
        expandedMounted = initial == .expanded
        expandedPhase = initial == .expanded ? .shown : .before
    }

    func go(_ t: IslandLayout) {
        guard t != target else { return }
        target = t
        work.forEach { $0.cancel() }
        work.removeAll()
        switch t {
        case .expanded: open()
        case .live: settle(into: .live)
        case .hidden: settle(into: .hidden)
        }
    }

    // MARK: Steps

    private func open() {
        let rm = reduceMotion
        quiet { visible = true; if !expandedMounted { expandedMounted = true; expandedPhase = .before } }
        if wingsMounted {
            withAnimation(rm ? Self.reducedEase : Motion.wingsFadeOut) { wingsShown = false }
            after(0.12) { [self] in quiet { wingsMounted = false } }
        }
        Log.hover.notice("present: shape->expanded")
        withAnimation(rm ? Self.reducedEase : Self.openSpring) { shape = .expanded }
        // Content starts a beat after the shape: opacity + scale 0.85 -> 1 + blur 8 -> 0.
        let lead = rm ? 0 : (expandedPhase == .before ? Motion.contentInDelay : Motion.contentInReinterruptDelay)
        after(lead) { [self] in
            withAnimation(rm ? Self.reducedEase : Motion.contentIn) { expandedPhase = .shown }
        }
    }

    /// Collapse into wings or into nothing: content leaves first and fast, then the shape settles.
    private func settle(into dest: IslandLayout) {
        let rm = reduceMotion
        let hadExpanded = expandedMounted
        quiet { visible = true }
        if hadExpanded {
            withAnimation(rm ? Self.reducedEase : Motion.contentOut) { expandedPhase = .after }
        }
        let shapeDelay = (hadExpanded && !rm) ? Motion.shrinkDelay : 0
        let anim: Animation = rm ? Self.reducedEase : (hadExpanded || dest == .hidden ? Self.closeSpring : Self.wingsSpring)

        if dest == .live {
            quiet { wingsMounted = true }
        } else if wingsMounted {
            withAnimation(rm ? Self.reducedEase : Motion.wingsFadeOut) { wingsShown = false }
        }
        after(shapeDelay) { [self] in Log.hover.notice("present: shape->\(String(describing: dest))"); withAnimation(anim) { shape = dest } }

        if dest == .live {
            after(shapeDelay + (rm ? 0 : Motion.wingsInDelay)) { [self] in
                withAnimation(Motion.wingsFadeIn) { wingsShown = true }
            }
            if hadExpanded { after(shapeDelay + Motion.unmountTime) { [self] in quiet { expandedMounted = false } } }
        } else {
            after(shapeDelay + (rm ? 0.2 : Motion.settleTime)) { [self] in
                Log.hover.notice("present: hidden"); withAnimation(.easeOut(duration: 0.1)) { visible = false }
            }
            after(shapeDelay + (rm ? 0.4 : Motion.unmountTime)) { [self] in
                quiet { expandedMounted = false; wingsMounted = false; wingsShown = false }
            }
        }
    }

    private func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        if delay <= 0 { block(); return }
        let w = DispatchWorkItem(block: block)
        work.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func quiet(_ body: () -> Void) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t, body)
    }
}

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var presenter: IslandPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        _presenter = StateObject(wrappedValue: IslandPresenter(initial: viewModel.layout))
    }

    var body: some View {
        ZStack(alignment: .top) {
            IslandView(viewModel: viewModel, presenter: presenter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { presenter.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, v in presenter.reduceMotion = v }
        .onChange(of: viewModel.layout) { _, new in
            presenter.reduceMotion = reduceMotion
            presenter.go(new)
        }
        .environment(\.palette, Palette(increased: contrast == .increased))
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

/// The black shape plus whichever content the presenter has mounted. The container has a fixed size;
/// only the shape path (and content opacity/scale/blur) animate, so no layout runs per frame.
struct IslandView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var presenter: IslandPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    private static let debug = CommandLine.arguments.contains("--debug-geometry")

    private func size(_ l: IslandLayout) -> CGSize {
        switch l {
        case .hidden: return viewModel.notchSize
        case .live: return CGSize(width: viewModel.notchSize.width + Metrics.wing * 2 + Metrics.liveEar * 2,
                                  height: viewModel.notchSize.height)
        case .expanded: return CGSize(width: viewModel.expandedBody.width + Metrics.expandedEar * 2,
                                      height: viewModel.expandedBody.height)
        }
    }
    private func ear(_ l: IslandLayout) -> CGFloat {
        switch l { case .expanded: return Metrics.expandedEar; case .live: return Metrics.liveEar; case .hidden: return 0 }
    }
    private func bottom(_ l: IslandLayout) -> CGFloat {
        switch l {
        case .expanded: return Metrics.expandedBottom
        case .live: return Metrics.liveBottom
        case .hidden: return Metrics.hardwareCornerRadius
        }
    }

    var body: some View {
        let l = presenter.shape
        let s = size(l)
        let full = size(.expanded)
        let shape = NotchShape(width: s.width, height: s.height, topRadius: ear(l), bottomRadius: bottom(l), topBleed: 4)
        let expanded = l == .expanded
        ZStack(alignment: .top) {
            shape.fill(palette.surface)
            if presenter.expandedMounted {
                ExpandedView()
                    .frame(width: full.width, height: full.height, alignment: .top)
                    .islandContent(presenter.expandedPhase, reduceMotion: reduceMotion)
            }
            if presenter.wingsMounted {
                LiveWingsView(viewModel: viewModel)
                    .frame(width: size(.live).width, height: size(.live).height, alignment: .top)
                    .opacity(presenter.wingsShown ? 1 : 0)
            }
        }
        .frame(width: full.width, height: full.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: expanded ? .black.opacity(0.4) : .clear,
                radius: expanded ? NotchGeometry.shadowRadius : 0,
                y: expanded ? NotchGeometry.shadowOffsetY : 0)
        .opacity(presenter.visible ? 1 : 0)
        .background(GeometryReader { g in
            Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                if Self.debug { print("SwiftUI island frame (global, top-left origin) layout=\(l) \(f)"); fflush(stdout) }
            }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacNotch")
    }
}
