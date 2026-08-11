import ButaiCore
import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Switches native Spaces with the same synthetic Dock-swipe mechanism used
/// by WhichSpace. This avoids dependence on user-configured Mission Control
/// keyboard shortcuts while leaving macOS in control of the actual switch.
actor PrivateSpaceNavigator: SpaceNavigating {
    private let provider: any SystemSpaceProviding
    private var generation = 0

    init(provider: any SystemSpaceProviding) {
        self.provider = provider
    }

    func navigate(from currentOrder: Int, to targetOrder: Int, workspaceCount: Int) async throws {
        _ = try NavigationIntent(
            currentOrder: currentOrder,
            targetOrder: targetOrder,
            workspaceCount: workspaceCount
        )
        guard let snapshot = provider.snapshot(),
              let currentIndex = snapshot.spaces.firstIndex(where: { $0.id == snapshot.currentSpaceID }),
              let targetIndex = snapshot.fullIndex(forRegularOrder: targetOrder) else {
            throw SpaceNavigationError.mappingUnreliable
        }
        guard currentIndex != targetIndex else { return }

        generation += 1
        let requestGeneration = generation
        guard generation == requestGeneration else { throw SpaceNavigationError.interrupted }

        // The dock-swipe path used by older releases is silently discarded by
        // the current macOS beta even with Accessibility enabled. Address the
        // target Desktop through macOS's own numbered symbolic hotkey instead;
        // this is the classic fallback used by WhichSpace and does not depend
        // on the user's current shortcut assignment or enabled state.
        guard postClassicDesktop(number: targetOrder) else {
            throw SpaceNavigationError.interrupted
        }
    }

    func cancel() {
        generation += 1
    }

    private func postSwipeGesture(goRight: Bool, velocity: Double) -> Bool {
        postDockSwipe(phase: 1, goRight: goRight, velocity: velocity)
            && postDockSwipe(phase: 2, goRight: goRight, velocity: velocity)
            && postDockSwipe(phase: 4, goRight: goRight, velocity: velocity)
    }

    /// A click action can run while AppKit still reports the mouse button as
    /// pressed. WindowServer silently discards synthetic swipe gestures in
    /// that state, so use the system's symbolic Mission Control hotkey for
    /// that step. This mirrors WhichSpace's click-to-switch fallback.
    private func postClassicDesktop(number: Int) -> Bool {
        guard (1...16).contains(number) else { return false }
        return postSymbolicHotKey(118 + Int32(number - 1))
    }

    private func postClassicStep(goRight: Bool) -> Bool {
        postSymbolicHotKey(goRight ? 81 : 79)
    }

    private func postSymbolicHotKey(_ hotKey: Int32) -> Bool {
        guard let symbols = SymbolicHotKeySymbols.shared else { return false }
        var keyCode: CGKeyCode = 0
        var flags: UInt32 = 0
        guard symbols.getValue(hotKey, nil, &keyCode, &flags) == .success else { return false }
        if symbols.isEnabled(hotKey) == 0,
           symbols.setEnabled(hotKey, 1) != .success { return false }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        keyDown.flags = CGEventFlags(rawValue: UInt64(flags))
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func postDockSwipe(phase: Int64, goRight: Bool, velocity: Double) -> Bool {
        guard let event = CGEvent(source: nil),
              let eventType = CGEventField(rawValue: 55),
              let gestureHIDType = CGEventField(rawValue: 110),
              let gestureSwipeMotion = CGEventField(rawValue: 123),
              let gestureSwipeProgress = CGEventField(rawValue: 124),
              let gestureSwipeVelocityX = CGEventField(rawValue: 129),
              let gestureSwipeVelocityY = CGEventField(rawValue: 130),
              let gesturePhase = CGEventField(rawValue: 132) else { return false }

        let progress = Double(Float.leastNonzeroMagnitude) * (goRight ? 1 : -1)
        let signedVelocity = velocity * (goRight ? 1 : -1)
        event.setIntegerValueField(eventType, value: 30)
        event.setIntegerValueField(gestureHIDType, value: 23)
        event.setIntegerValueField(gesturePhase, value: phase)
        event.setDoubleValueField(gestureSwipeProgress, value: progress)
        event.setIntegerValueField(gestureSwipeMotion, value: 1)
        event.setDoubleValueField(gestureSwipeVelocityX, value: signedVelocity)
        event.setDoubleValueField(gestureSwipeVelocityY, value: signedVelocity)
        event.post(tap: .cgSessionEventTap)
        return true
    }
}

private final class SymbolicHotKeySymbols: @unchecked Sendable {
    typealias GetValue = @convention(c) (
        Int32, UnsafeMutablePointer<UniChar>?, UnsafeMutablePointer<CGKeyCode>?, UnsafeMutablePointer<UInt32>?
    ) -> CGError
    typealias IsEnabled = @convention(c) (Int32) -> UInt8
    typealias SetEnabled = @convention(c) (Int32, UInt8) -> CGError

    static let shared: SymbolicHotKeySymbols? = SymbolicHotKeySymbols()

    let getValue: GetValue
    let isEnabled: IsEnabled
    let setEnabled: SetEnabled
    private let handle: UnsafeMutableRawPointer

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let getValue = dlsym(handle, "CGSGetSymbolicHotKeyValue"),
              let isEnabled = dlsym(handle, "CGSIsSymbolicHotKeyEnabled"),
              let setEnabled = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        self.handle = handle
        self.getValue = unsafeBitCast(getValue, to: GetValue.self)
        self.isEnabled = unsafeBitCast(isEnabled, to: IsEnabled.self)
        self.setEnabled = unsafeBitCast(setEnabled, to: SetEnabled.self)
    }

    deinit { dlclose(handle) }
}
