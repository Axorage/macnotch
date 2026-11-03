import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel pinned top-center of the built-in screen.
/// The frame is set once (max expanded size) and never animated; SwiftUI animates the island inside.
final class NotchPanel: NSPanel {
    let viewModel: NotchViewModel
    private let hostView: NotchHostingView<AnyView>
    private var geometry: NotchGeometry
    private var cancellables = Set<AnyCancellable>()
    private var wantsKey = false
    /// Tiny panel over the collapsed/wings island: the only mouse-catching window while not expanded.
    private var sensor: HoverSensorPanel?
    private var spacePinned = false

    @MainActor
    init(appState: AppState) {
        let screen = NotchGeometry.builtInScreen()
        let geo = screen.map { NotchGeometry.compute(for: $0) } ?? NotchGeometry.placeholder()
        geometry = geo
        viewModel = NotchViewModel(geometry: geo, appState: appState)

        let root = AnyView(NotchRootView(viewModel: viewModel).environmentObject(appState).environmentObject(viewModel))
        hostView = NotchHostingView(rootView: root)

        super.init(contentRect: geo.panelFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        setAccessibilityLabel("MacNotch")

        hostView.frame = NSRect(origin: .zero, size: geo.panelFrame.size)
        hostView.autoresizingMask = [.width, .height]
        hostView.viewModel = viewModel
        if #available(macOS 13.3, *) { hostView.safeAreaRegions = [] }
        hostView.interactiveSize = { [weak self] in
            MainActor.assumeIsolated { self?.viewModel.interactiveSize ?? .zero }
        }
        contentView = hostView
        setFrame(geo.panelFrame, display: false)
        setScreenAvailable(screen != nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Tracking area + hit-testing follow the visible shape (collapsed, wings, expanded).
        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.hostView.refreshTracking(); self?.syncMouseMode() }
            .store(in: &cancellables)
        viewModel.isPointerInIsland = { [weak self] in
            guard let self else { return false }
            let p = self.hostView.convert(self.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            return self.hostView.contains(interactivePoint: p)
        }
        viewModel.isPointerInSensor = { [weak self] in
            guard let self, let f = self.sensor?.frame else { return false }
            return f.contains(NSEvent.mouseLocation)
        }
        viewModel.isPointerInExpandedTarget = { [weak self] in
            guard let self else { return false }
            let slop = NotchHostingView<AnyView>.slop + 2
            let r = self.hostView.interactiveViewRect(size: self.viewModel.expandedSizeForDebug).insetBy(dx: -slop, dy: -slop)
            return self.convertToScreen(self.hostView.convert(r, to: nil)).contains(NSEvent.mouseLocation)
        }
        viewModel.onStickyChange = { [weak self] on in self?.stickyChanged(on) }
        hostView.refreshTracking()
        let sensor = HoverSensorPanel()
        sensor.onEnter = { [weak self] in MainActor.assumeIsolated { self?.viewModel.sensorEntered() } }
        sensor.onExit = { [weak self] in MainActor.assumeIsolated { self?.viewModel.sensorExited() } }
        sensor.onClick = { [weak self] in MainActor.assumeIsolated { self?.viewModel.expandNow() } }
        self.sensor = sensor
        // Keep both windows fixed while Spaces slide (private SkyLight, guarded; on failure windows are left as-is).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.installSpaceBehavior() }
        }
        syncMouseMode()
        if CommandLine.arguments.contains("--debug-geometry") { debugDump(screen) }
    }

    /// Never let AppKit push the panel below the menu bar: its top must equal screen.frame.maxY.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// AppKit calls makeKey on every left mouse-up routed to the window (_routeLeftMouseUpEvent), which logs
    /// "canBecomeKeyWindow returned NO" while we are not sticky. Only forward when we actually want key.
    override func makeKey() {
        guard wantsKey else { return }
        super.makeKey()
    }
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    @MainActor private func stickyChanged(_ on: Bool) {
        wantsKey = on
        if on {
            makeKey()
        } else if isKeyWindow {
            // Drop key status without activating anything else.
            makeFirstResponder(nil)
            orderOut(nil)
            orderFrontRegardless()
        }
    }

    /// The big panel catches mouse events (even over transparent pixels) for its whole frame, which would block
    /// every app under it. So it only takes events while expanded; otherwise a sensor sized to the visible
    /// island (hardware notch / wings) handles hover and click.
    @MainActor private func syncMouseMode() {
        guard alphaValue > 0 else { sensor?.orderOut(nil); return }
        let expanded = viewModel.isExpanded
        if ignoresMouseEvents == expanded {
            ignoresMouseEvents = !expanded
            if DebugSettings.enabled || CommandLine.arguments.contains("--debug-mouse") {
                DebugSettings.log.notice("NotchPanel ignoresMouseEvents=\(self.ignoresMouseEvents) frame=\(NSStringFromRect(self.frame), privacy: .public)")
            }
        }
        let size = viewModel.interactiveSize
        if expanded || size == .zero {
            if sensor?.isVisible == true { sensor?.orderOut(nil) }
            return
        }
        let r = hostView.interactiveViewRect(size: size).insetBy(dx: -NotchHostingView<AnyView>.slop, dy: -NotchHostingView<AnyView>.slop)
        let screenRect = convertToScreen(hostView.convert(r, to: nil))
        if sensor?.frame != screenRect {
            sensor?.setFrame(screenRect, display: false)
            if DebugSettings.enabled || CommandLine.arguments.contains("--debug-mouse") {
                DebugSettings.log.notice("HoverSensor frame=\(NSStringFromRect(screenRect), privacy: .public)")
            }
        }
        if sensor?.isVisible != true { sensor?.orderFrontRegardless() }
    }

    @MainActor private func installSpaceBehavior() {
        guard let sensor else { return }
        sensor.orderFrontRegardless()   // windows need a server-side presence before moving between Spaces
        spacePinned = SpacePinner.shared.pin([self, sensor])
        if DebugSettings.enabled || CommandLine.arguments.contains("--debug-mouse") {
            DebugSettings.log.notice("spacePinned=\(self.spacePinned)")
        }
        syncMouseMode()
    }

    /// With no screen attached, skip layout: stay invisible and inert until a screen returns.
    @MainActor private func setScreenAvailable(_ available: Bool) {
        alphaValue = available ? 1 : 0
        ignoresMouseEvents = true
        if !available { sensor?.orderOut(nil) }
    }

    @MainActor @objc private func screenChanged() {
        guard let screen = NotchGeometry.builtInScreen() else { setScreenAvailable(false); return }
        setScreenAvailable(true)
        let geo = NotchGeometry.compute(for: screen)
        guard geo != geometry else { return }
        geometry = geo
        viewModel.update(geometry: geo)
        setFrame(geo.panelFrame, display: false)
        hostView.refreshTracking()
        syncMouseMode()
    }

    override func sendEvent(_ event: NSEvent) {
        if DebugSettings.enabled, event.type == .leftMouseDown || event.type == .leftMouseUp {
            DebugSettings.log.notice("NotchPanel.sendEvent type=\(event.type.rawValue) locInWindow=\(NSStringFromPoint(event.locationInWindow), privacy: .public) screen=\(NSStringFromPoint(NSEvent.mouseLocation), privacy: .public)")
        }
        if event.type == .leftMouseDown {
            let p = hostView.convert(event.locationInWindow, from: nil)
            if !hostView.contains(interactivePoint: p) {
                // Panel margin outside the drawn island: a click there while pinned is an outside click.
                MainActor.assumeIsolated { if viewModel.isSticky { viewModel.collapse() } }
            } else {
                MainActor.assumeIsolated {
                    // Clicks never pin the panel: hovering out still dismisses it. Opening a note (editor)
                    // makes it sticky via the view model; Esc / outside click still close.
                    if viewModel.layout != .expanded { viewModel.expandNow() }
                }
            }
        }
        super.sendEvent(event)
    }

    @MainActor private func debugDump(_ screen: NSScreen?) {
        let r = hostView.interactiveViewRect(size: viewModel.interactiveSize)
        let hr = hostView.interactiveViewRect(size: CGSize(width: geometry.notchSize.width, height: geometry.notchSize.height + NotchGeometry.hoverSlopBelow))
        var lines = [
            "screen.frame=\(screen?.frame ?? .zero) insets.top=\(screen?.safeAreaInsets.top ?? 0)",
            "auxLeft=\(String(describing: screen?.auxiliaryTopLeftArea)) auxRight=\(String(describing: screen?.auxiliaryTopRightArea))",
            "notchSize=\(geometry.notchSize) -> notch screen x \((screen?.frame.midX ?? 0) - geometry.notchSize.width / 2)...\((screen?.frame.midX ?? 0) + geometry.notchSize.width / 2)",
            "panelFrame=\(frame) panel.maxY=\(frame.maxY) screen.maxY=\(screen?.frame.maxY ?? 0) topAligned=\(frame.maxY == (screen?.frame.maxY ?? -1)) shapeTop(view y)=0 bleed=4",
            "panelFrame=\(frame) hostView.isFlipped=\(hostView.isFlipped) bounds=\(hostView.bounds)",
            "hover rect (view)=\(hr) (screen)=\(convertToScreen(hostView.convert(hr, to: nil)))",
            "current interactive rect (view)=\(r)",
        ]
        lines.append("expanded rect (view)=\(hostView.interactiveViewRect(size: viewModel.expandedSizeForDebug))")
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }

    override func keyDown(with event: NSEvent) {
        let handled = MainActor.assumeIsolated {
            viewModel.handleKey(keyCode: event.keyCode,
                                command: event.modifierFlags.contains(.command),
                                textFocused: firstResponder is NSText)
        }
        if !handled { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let handled = MainActor.assumeIsolated {
            viewModel.handleKey(keyCode: event.keyCode, command: true, textFocused: firstResponder is NSText)
        }
        return handled || super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated {
            if viewModel.isSticky && wantsKey { viewModel.collapse() }
        }
    }
}

/// Island-sized, clear, non-activating panel that reports hover/click while the main panel ignores the mouse.
final class HoverSensorPanel: NSPanel {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setAccessibilityElement(false)
        contentView = SensorView(owner: self)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private final class SensorView: NSView {
        unowned let owner: HoverSensorPanel
        init(owner: HoverSensorPanel) {
            self.owner = owner
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { owner.onEnter() }
        override func mouseExited(with event: NSEvent) { owner.onExit() }
        override func mouseDown(with event: NSEvent) { owner.onClick() }
    }
}

/// Hosting view that lets clicks fall through outside the active region and
/// reports hover via a single NSTrackingArea (no global mouse monitors).
///
/// Coordinates: NSHostingView is flipped (origin top-left) while a plain NSView is not, so the
/// active rect is always derived from `isFlipped` and `bounds`, never assumed.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    weak var viewModel: NotchViewModel?
    /// Size of the top-centered active region (zero = none).
    var interactiveSize: () -> CGSize = { .zero }
    private var area: NSTrackingArea?
    private var lastRect: CGRect = .null
    static var slop: CGFloat { 2 }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Top-centered rect of `size` in this view's own coordinate space.
    func interactiveViewRect(size: CGSize) -> CGRect {
        guard size != .zero else { return .zero }
        let x = (bounds.width - size.width) / 2
        let y = isFlipped ? 0 : bounds.height - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func contains(interactivePoint p: NSPoint) -> Bool {
        let r = interactiveViewRect(size: interactiveSize())
        return !r.isEmpty && r.insetBy(dx: -Self.slop, dy: -Self.slop).contains(p)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard contains(interactivePoint: convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        refreshTracking()
    }

    func refreshTracking() {
        let rect = interactiveViewRect(size: interactiveSize())
        guard rect != lastRect else { return }
        lastRect = rect
        if let area { removeTrackingArea(area); self.area = nil }
        guard !rect.isEmpty else { return }
        defer { reconcilePointer(in: rect) }
        let a = NSTrackingArea(rect: rect.insetBy(dx: -Self.slop, dy: -Self.slop),
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    /// A rebuilt tracking area emits no exit event if the pointer is already outside the new rect:
    /// synthesize it so the dismiss timer still starts.
    private func reconcilePointer(in rect: CGRect) {
        guard let window, viewModel != nil else { return }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if !rect.insetBy(dx: -Self.slop, dy: -Self.slop).contains(p) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.viewModel else { return }
                MainActor.assumeIsolated { vm.panelPointer(inside: false) }
            }
        }
    }

    // NSHostingView installs its own full-bounds tracking areas owned by `self`; only react to ours,
    // otherwise hovering anywhere in the (transparent) panel would count as hovering the island.
    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === area else { super.mouseEntered(with: event); return }
        MainActor.assumeIsolated { viewModel?.panelPointer(inside: true) }
    }
    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === area else { super.mouseExited(with: event); return }
        MainActor.assumeIsolated { viewModel?.panelPointer(inside: false) }
    }
}
