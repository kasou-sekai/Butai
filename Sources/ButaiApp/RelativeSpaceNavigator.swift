import ApplicationServices
import AppKit
import ButaiCore
import CoreGraphics
import Darwin
import Foundation

/// Switches native Spaces through the user's live left/right Space shortcuts.
/// Every step is confirmed against WindowServer before the next is sent, so a
/// key event dropped during an animation is retried instead of leaving Butai
/// on the wrong Desktop. No shortcut is enabled or rewritten by Butai.
actor PrivateSpaceNavigator: SpaceNavigating {
    private static let moveLeftHotKey: Int32 = 79
    private static let moveRightHotKey: Int32 = 81
    private static let maximumStepAttempts = 3
    private static let maximumNavigationIterations = 32
    private static let mouseReleasePollCount = 60
    private static let stepChangePollCount = 24
    private static let mousePollInterval = Duration.milliseconds(20)
    private static let mouseReleaseDebounceDelay = Duration.milliseconds(40)
    private static let keyPressDuration = Duration.milliseconds(80)
    private static let postKeyDelay = Duration.milliseconds(30)
    private static let stepChangePollInterval = Duration.milliseconds(50)
    private static let stepSettleDelay = Duration.milliseconds(300)
    private static let retryDelay = Duration.milliseconds(100)

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
        try await waitForMouseRelease(requestGeneration: requestGeneration)

        guard let initialSnapshot = provider.snapshot(),
              initialSnapshot.regularSpaces.indices.contains(targetOrder - 1) else {
            throw SpaceNavigationError.mappingUnreliable
        }
        let targetSpaceID = initialSnapshot.regularSpaces[targetOrder - 1].id
        guard initialSnapshot.currentSpaceID != targetSpaceID else { return }

        for _ in 0..<Self.maximumNavigationIterations {
            try ensureCurrent(requestGeneration)
            guard let snapshot = provider.snapshot(),
                  snapshot.regularSpaces.indices.contains(targetOrder - 1),
                  snapshot.regularSpaces[targetOrder - 1].id == targetSpaceID,
                  let currentIndex = snapshot.spaces.firstIndex(
                      where: { $0.id == snapshot.currentSpaceID }
                  ),
                  let targetIndex = snapshot.spaces.firstIndex(
                      where: { $0.id == targetSpaceID }
                  ) else {
                throw SpaceNavigationError.mappingUnreliable
            }
            guard currentIndex != targetIndex else { return }

            let hotKey = targetIndex < currentIndex
                ? Self.moveLeftHotKey
                : Self.moveRightHotKey
            if try await performConfirmedStep(
                hotKey: hotKey,
                fromSpaceID: snapshot.currentSpaceID,
                targetSpaceID: targetSpaceID,
                requestGeneration: requestGeneration
            ) {
                return
            }
        }

        throw SpaceNavigationError.timedOut
    }

    func cancel() {
        generation += 1
    }

    private func performConfirmedStep(
        hotKey: Int32,
        fromSpaceID: Int,
        targetSpaceID: Int,
        requestGeneration: Int
    ) async throws -> Bool {
        for attempt in 0..<Self.maximumStepAttempts {
            try ensureCurrent(requestGeneration)
            guard await postConfiguredSymbolicHotKey(hotKey) else {
                throw SpaceNavigationError.timedOut
            }

            if let changedSnapshot = try await waitForSpaceChange(
                fromSpaceID: fromSpaceID,
                requestGeneration: requestGeneration
            ) {
                if changedSnapshot.currentSpaceID == targetSpaceID {
                    return true
                }
                try await Task.sleep(for: Self.stepSettleDelay)
                return false
            }

            if attempt < Self.maximumStepAttempts - 1 {
                try await Task.sleep(for: Self.retryDelay)
            }
        }
        throw SpaceNavigationError.timedOut
    }

    /// SwiftUI can invoke the button action before AppKit observes mouse-up.
    /// Give WindowServer an extra frame after release so the first chord is not
    /// swallowed by the still-finishing click transaction.
    private func waitForMouseRelease(requestGeneration: Int) async throws {
        for _ in 0..<Self.mouseReleasePollCount {
            try ensureCurrent(requestGeneration)
            let pressedButtons = await MainActor.run { NSEvent.pressedMouseButtons }
            if pressedButtons == 0 {
                try await Task.sleep(for: Self.mouseReleaseDebounceDelay)
                try ensureCurrent(requestGeneration)
                return
            }
            try await Task.sleep(for: Self.mousePollInterval)
        }
        throw SpaceNavigationError.timedOut
    }

    private func waitForSpaceChange(
        fromSpaceID: Int,
        requestGeneration: Int
    ) async throws -> SystemSpaceSnapshot? {
        for _ in 0..<Self.stepChangePollCount {
            try await Task.sleep(for: Self.stepChangePollInterval)
            try ensureCurrent(requestGeneration)
            if let snapshot = provider.snapshot(), snapshot.currentSpaceID != fromSpaceID {
                return snapshot
            }
        }
        return nil
    }

    /// Posts the exact symbolic hotkey currently registered with WindowServer.
    /// A private event source matches Hammerspoon's proven eventtap path, while
    /// the short hold interval avoids a zero-duration chord.
    private func postConfiguredSymbolicHotKey(_ hotKey: Int32) async -> Bool {
        guard let symbols = SymbolicHotKeySymbols.shared,
              symbols.isEnabled(hotKey) != 0 else {
            return false
        }

        var keyCode: CGKeyCode = 0
        var rawFlags: UInt32 = 0
        guard symbols.getValue(hotKey, nil, &keyCode, &rawFlags) == .success,
              keyCode != CGKeyCode.max,
              let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: false
              ) else {
            return false
        }

        source.localEventsSuppressionInterval = 0
        let flags = CGEventFlags(rawValue: UInt64(rawFlags))
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: Self.keyPressDuration)
        // Always emit key-up even when a newer request cancels this task.
        keyUp.post(tap: .cghidEventTap)
        try? await Task.sleep(for: Self.postKeyDelay)
        return true
    }

    private func ensureCurrent(_ requestGeneration: Int) throws {
        guard generation == requestGeneration, !Task.isCancelled else {
            throw SpaceNavigationError.interrupted
        }
    }
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
