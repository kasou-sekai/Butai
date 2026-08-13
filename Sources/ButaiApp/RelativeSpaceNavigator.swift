import ApplicationServices
import AppKit
import ButaiCore
import CoreGraphics
import Darwin
import Foundation

/// Switches native Spaces through a confirmed chain of no-SIP backends:
/// direct SkyLight activation plus a complete Dock refresh cycle, the user's
/// existing numbered Desktop action, then high-velocity Dock gestures. No
/// backend mutates system shortcuts.
actor PrivateSpaceNavigator: SpaceNavigating {
    private static let maximumAttempts = 3
    private static let directSpacePollCount = 16
    private static let directTransitionPollCount = 24
    private static let mouseReleasePollCount = 60
    private static let transitionPollCount = 30
    private static let pollInterval = Duration.milliseconds(20)
    private static let transitionPollInterval = Duration.milliseconds(50)

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
        guard AXIsProcessTrusted() else {
            throw SpaceNavigationError.permissionDenied
        }

        generation += 1
        let requestGeneration = generation

        // A SwiftUI Button action may run before AppKit has observed mouse-up.
        // WindowServer silently drops synthetic Dock gestures while a mouse
        // button is held, which made click-to-switch fail intermittently.
        try await waitForMouseRelease(requestGeneration: requestGeneration)

        // Restore the direct backend used by Butai 0.5.14-0.5.16. On the
        // current macOS 27 seed this private call switches reliably without
        // keyboard configuration or a disabled-SIP Dock injection. The UI
        // layer keeps Butai's status-bar panels ordered out until the target
        // is confirmed, preventing their old cross-Space afterimage.
        if await setCurrentSpaceDirectly(targetOrder: targetOrder) {
            if try await waitForTarget(
                targetOrder: targetOrder,
                requestGeneration: requestGeneration,
                pollCount: Self.directSpacePollCount
            ) {
                return
            }
        }

        // The numbered Mission Control action was the only backend observed
        // to work consistently on this macOS 27 seed. Reuse the user's live
        // registration without ever enabling or rewriting it. If it is absent
        // or WindowServer ignores it, continue with the no-shortcut gesture
        // backend below.
        if postConfiguredDesktopHotKey(number: targetOrder),
           try await waitForTarget(
               targetOrder: targetOrder,
               requestGeneration: requestGeneration,
               pollCount: Self.directTransitionPollCount
           ) {
            return
        }

        for _ in 0..<Self.maximumAttempts {
            try ensureCurrent(requestGeneration)
            guard let snapshot = provider.snapshot(),
                  snapshot.regularSpaces.indices.contains(targetOrder - 1),
                  let currentIndex = snapshot.spaces.firstIndex(
                      where: { $0.id == snapshot.currentSpaceID }
                  ) else {
                throw SpaceNavigationError.mappingUnreliable
            }

            let targetSpaceID = snapshot.regularSpaces[targetOrder - 1].id
            guard snapshot.currentSpaceID != targetSpaceID else { return }
            guard let targetIndex = snapshot.spaces.firstIndex(
                where: { $0.id == targetSpaceID }
            ) else {
                throw SpaceNavigationError.mappingUnreliable
            }

            let stepCount = abs(targetIndex - currentIndex)
            let goRight = targetIndex > currentIndex
            guard postDockSwipeSteps(count: stepCount, goRight: goRight) else {
                throw SpaceNavigationError.interrupted
            }

            if try await waitForTarget(
                targetOrder: targetOrder,
                requestGeneration: requestGeneration,
                pollCount: Self.transitionPollCount
            ) {
                return
            }
        }

        throw SpaceNavigationError.timedOut
    }

    func cancel() {
        generation += 1
    }

    private func waitForMouseRelease(requestGeneration: Int) async throws {
        for _ in 0..<Self.mouseReleasePollCount {
            try ensureCurrent(requestGeneration)
            let pressedButtons = await MainActor.run { NSEvent.pressedMouseButtons }
            if pressedButtons == 0 { return }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw SpaceNavigationError.timedOut
    }

    private func waitForTarget(
        targetOrder: Int,
        requestGeneration: Int,
        pollCount: Int
    ) async throws -> Bool {
        for _ in 0..<pollCount {
            try await Task.sleep(for: Self.transitionPollInterval)
            try ensureCurrent(requestGeneration)
            guard let snapshot = provider.snapshot(),
                  snapshot.regularSpaces.indices.contains(targetOrder - 1) else {
                continue
            }
            if snapshot.currentSpaceID == snapshot.regularSpaces[targetOrder - 1].id {
                return true
            }
        }
        return false
    }

    private func setCurrentSpaceDirectly(targetOrder: Int) async -> Bool {
        guard let symbols = DirectSpaceSymbols.shared,
              let snapshot = provider.snapshot(),
              snapshot.regularSpaces.indices.contains(targetOrder - 1) else {
            return false
        }
        let targetSpaceID = snapshot.regularSpaces[targetOrder - 1].id
        guard snapshot.currentSpaceID != targetSpaceID else { return true }
        guard let targetIndex = snapshot.spaces.firstIndex(
            where: { $0.id == targetSpaceID }
        ) else {
            return false
        }
        symbols.setCurrentSpace(
            symbols.defaultConnection(),
            snapshot.displayID as CFString,
            UInt64(targetSpaceID)
        )

        // Direct activation mutates WindowServer state but does not make Dock
        // emit kCGSSpaceDidChange. Drive a complete, net-zero pair through
        // Dock's gesture pipeline so it refreshes its Space bookkeeping and
        // the menu-bar/compositor surfaces. Start toward a real neighbour so
        // the first half cannot be discarded at the end of the Space list.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return false }
        let firstRight = targetIndex < snapshot.spaces.count - 1
        guard postDockRefreshCycle(firstRight: firstRight) else { return false }
        return true
    }

    /// Posts the exact numbered Desktop action currently registered with
    /// WindowServer. Unlike older Butai builds this is strictly read-only: a
    /// disabled or missing action is skipped instead of being enabled or
    /// temporarily rebound, so an interruption cannot corrupt user settings.
    private func postConfiguredDesktopHotKey(number: Int) -> Bool {
        guard (1...16).contains(number),
              let symbols = SymbolicHotKeySymbols.shared else {
            return false
        }
        let hotKey = Int32(118 + number - 1)
        guard symbols.isEnabled(hotKey) != 0 else { return false }

        var keyCode: CGKeyCode = 0
        var flags: UInt32 = 0
        guard symbols.getValue(hotKey, nil, &keyCode, &flags) == .success,
              keyCode != CGKeyCode.max else {
            return false
        }
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            return false
        }

        keyDown.flags = CGEventFlags(rawValue: UInt64(flags))
        keyDown.post(tap: .cghidEventTap)
        keyUp.flags = []
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func ensureCurrent(_ requestGeneration: Int) throws {
        guard generation == requestGeneration, !Task.isCancelled else {
            throw SpaceNavigationError.interrupted
        }
    }

    /// SLSManagedDisplaySetCurrentSpace leaves Dock out of the transition, so
    /// no kCGSSpaceDidChange notification reaches the compositor. A complete
    /// swipe to an adjacent Space and its inverse has zero net movement while
    /// forcing Dock to publish the missing notifications. Unlike the old
    /// low-velocity nudge, every Dock event is paired with the type-29 gesture
    /// event and includes the fields required by Dock's event filter.
    private func postDockRefreshCycle(firstRight: Bool) -> Bool {
        postCompleteDockSwipe(goRight: firstRight)
            && postCompleteDockSwipe(goRight: !firstRight)
    }

    private func postCompleteDockSwipe(goRight: Bool) -> Bool {
        postDockSwipePhase(phase: 1, goRight: goRight, carriesMomentum: false)
            && postDockSwipePhase(phase: 4, goRight: goRight, carriesMomentum: true)
    }

    private func postDockSwipePhase(
        phase: Int64,
        goRight: Bool,
        carriesMomentum: Bool
    ) -> Bool {
        guard let dockEvent = CGEvent(source: nil),
              let companionEvent = CGEvent(source: nil),
              let eventType = CGEventField(rawValue: 55),
              let gestureHIDType = CGEventField(rawValue: 110),
              let gestureScrollY = CGEventField(rawValue: 119),
              let gestureSwipeMotion = CGEventField(rawValue: 123),
              let gestureSwipeProgress = CGEventField(rawValue: 124),
              let gestureSwipeVelocityX = CGEventField(rawValue: 129),
              let gesturePhase = CGEventField(rawValue: 132),
              let scrollGestureFlagBits = CGEventField(rawValue: 135),
              let gestureZoomDeltaX = CGEventField(rawValue: 139) else {
            return false
        }

        companionEvent.setIntegerValueField(eventType, value: 29)

        dockEvent.setIntegerValueField(eventType, value: 30)
        dockEvent.setIntegerValueField(gestureHIDType, value: 23)
        dockEvent.setIntegerValueField(gesturePhase, value: phase)
        dockEvent.setIntegerValueField(scrollGestureFlagBits, value: goRight ? 1 : 0)
        dockEvent.setIntegerValueField(gestureSwipeMotion, value: 1)
        dockEvent.setDoubleValueField(gestureScrollY, value: 0)
        dockEvent.setDoubleValueField(
            gestureZoomDeltaX,
            value: Double(Float.leastNonzeroMagnitude)
        )

        if carriesMomentum {
            let direction = goRight ? 1.0 : -1.0
            dockEvent.setDoubleValueField(gestureSwipeProgress, value: direction * 2)
            dockEvent.setDoubleValueField(gestureSwipeVelocityX, value: direction * 400)
        }

        dockEvent.post(tap: .cgSessionEventTap)
        companionEvent.post(tap: .cgSessionEventTap)
        return true
    }

    /// Posts the gesture profile used by yabai's no-scripting-addition path:
    /// full signed progress, very high horizontal velocity, and began/ended
    /// phases. Posting one pair per intervening Space makes distant jumps
    /// effectively instant while macOS remains responsible for activation.
    private func postDockSwipeSteps(count: Int, goRight: Bool) -> Bool {
        guard count > 0,
              let event = CGEvent(source: nil),
              let eventType = CGEventField(rawValue: 55),
              let gestureHIDType = CGEventField(rawValue: 110),
              let gestureSwipeMotion = CGEventField(rawValue: 123),
              let gestureSwipeProgress = CGEventField(rawValue: 124),
              let gestureSwipeVelocityX = CGEventField(rawValue: 129),
              let gesturePhase = CGEventField(rawValue: 132) else {
            return false
        }

        let direction = goRight ? 1.0 : -1.0
        event.setIntegerValueField(eventType, value: 30)
        event.setIntegerValueField(gestureHIDType, value: 23)
        event.setIntegerValueField(gestureSwipeMotion, value: 1)
        event.setDoubleValueField(gestureSwipeProgress, value: direction)
        event.setDoubleValueField(gestureSwipeVelocityX, value: direction * 9_999)

        for _ in 0..<count {
            event.setIntegerValueField(gesturePhase, value: 1)
            event.post(tap: .cgSessionEventTap)
            event.setIntegerValueField(gesturePhase, value: 4)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }
}

private final class DirectSpaceSymbols: @unchecked Sendable {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias SetCurrentSpace = @convention(c) (Int32, CFString, UInt64) -> Void

    static let shared: DirectSpaceSymbols? = DirectSpaceSymbols()

    let defaultConnection: DefaultConnection
    let setCurrentSpace: SetCurrentSpace
    private let handle: UnsafeMutableRawPointer

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let defaultConnection = dlsym(handle, "_CGSDefaultConnection"),
              let setCurrentSpace = dlsym(handle, "SLSManagedDisplaySetCurrentSpace") else {
            return nil
        }
        self.handle = handle
        self.defaultConnection = unsafeBitCast(defaultConnection, to: DefaultConnection.self)
        self.setCurrentSpace = unsafeBitCast(setCurrentSpace, to: SetCurrentSpace.self)
    }

    deinit { dlclose(handle) }
}

private final class SymbolicHotKeySymbols: @unchecked Sendable {
    typealias GetValue = @convention(c) (
        Int32,
        UnsafeMutablePointer<UniChar>?,
        UnsafeMutablePointer<CGKeyCode>?,
        UnsafeMutablePointer<UInt32>?
    ) -> CGError
    typealias IsEnabled = @convention(c) (Int32) -> UInt8

    static let shared: SymbolicHotKeySymbols? = SymbolicHotKeySymbols()

    let getValue: GetValue
    let isEnabled: IsEnabled
    private let handle: UnsafeMutableRawPointer

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let getValue = dlsym(handle, "CGSGetSymbolicHotKeyValue"),
              let isEnabled = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") else {
            return nil
        }
        self.handle = handle
        self.getValue = unsafeBitCast(getValue, to: GetValue.self)
        self.isEnabled = unsafeBitCast(isEnabled, to: IsEnabled.self)
    }

    deinit { dlclose(handle) }
}
