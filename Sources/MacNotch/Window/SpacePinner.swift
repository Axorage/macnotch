import AppKit

/// Keeps windows fixed on screen while macOS slides between Spaces, by moving them into a private
/// top-level "system" Space created through SkyLight (the technique used by boring.notch's SkyLightOperator).
/// PRIVATE API: symbols are resolved at runtime with dlopen/dlsym; every step is guarded. If anything is
/// missing or fails, `pin` returns false and the caller falls back to hide/re-show on Space change.
@MainActor
final class SpacePinner {
    static let shared = SpacePinner()

    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> Int32
    private typealias SetLevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private var cid: Int32 = 0
    private var space: Int32 = 0
    private var addWindows: AddWindowsFn?
    private var ready = false
    private var attempted = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: "ui.pinAcrossSpaces") as? Bool ?? true }

    private func setup() {
        guard !attempted else { return }
        attempted = true
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let pMain = dlsym(h, "SLSMainConnectionID"),
              let pCreate = dlsym(h, "SLSSpaceCreate"),
              let pLevel = dlsym(h, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(h, "SLSShowSpaces"),
              let pAdd = dlsym(h, "SLSAddWindowsToSpaces") else { return }
        let main = unsafeBitCast(pMain, to: MainConnFn.self)
        let create = unsafeBitCast(pCreate, to: SpaceCreateFn.self)
        let level = unsafeBitCast(pLevel, to: SetLevelFn.self)
        let show = unsafeBitCast(pShow, to: ShowSpacesFn.self)
        cid = main()
        guard cid != 0 else { return }
        space = create(cid, 1, nil)
        guard space != 0 else { return }
        _ = level(cid, space, 2147483647)
        _ = show(cid, [space] as CFArray)
        addWindows = unsafeBitCast(pAdd, to: AddWindowsFn.self)
        ready = true
    }

    /// Returns true if all windows were delegated to the fixed Space.
    func pin(_ windows: [NSWindow]) -> Bool {
        guard Self.enabled else { return false }
        setup()
        if CommandLine.arguments.contains("--debug-mouse") { DebugSettings.log.notice("SpacePinner ready=\(self.ready) cid=\(self.cid) space=\(self.space)") }
        guard ready, let add = addWindows else { return false }
        let ids = windows.map { NSNumber(value: $0.windowNumber) }
        guard !ids.isEmpty, !ids.contains(where: { $0.intValue <= 0 }) else { return false }
        let rc = add(cid, ids as CFArray, [space] as CFArray)
        if CommandLine.arguments.contains("--debug-mouse") { DebugSettings.log.notice("SpacePinner cid=\(self.cid) space=\(self.space) ids=\(ids.map(\.intValue)) rc=\(rc)") }
        return rc == 0
    }
}
