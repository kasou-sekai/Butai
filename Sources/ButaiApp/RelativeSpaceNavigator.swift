import ApplicationServices
import AppKit
import ButaiCore
import CoreGraphics
import Darwin
import Foundation

/// Switches directly through macOS's configured "Switch to Desktop N"
/// symbolic actions. This is the navigation path used by Butai 0.5.17:
/// one target action is posted, with no adjacent-Space loop and no Dock or
/// Mission Control automation.
actor PrivateSpaceNavigator: SpaceNavigating {
    private static let mouseReleasePollCount = 60
    private static let transitionPollCount = 40
    private static let mousePollInterval = Duration.milliseconds(20)
    private static let mouseReleaseDebounceDelay = Duration.milliseconds(40)
    private static let keyPressDuration = Duration.milliseconds(80)
    private static let postKeyDelay = Duration.milliseconds(30)
    private static let transitionPollInterval = Duration.milliseconds(50)
    private static let interStageDelay = Duration.milliseconds(260)
    private static let interAdjacentStepDelay = Duration.milliseconds(180)

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

        guard let snapshot = provider.snapshot(),
              snapshot.regularSpaces.indices.contains(targetOrder - 1) else {
            throw SpaceNavigationError.mappingUnreliable
        }
        let targetSpaceID = snapshot.regularSpaces[targetOrder - 1].id
        guard snapshot.currentSpaceID != targetSpaceID else { return }

        guard try await postConfiguredDesktopHotKey(
            number: targetOrder,
            requestGeneration: requestGeneration
        ) else {
            throw SpaceNavigationError.timedOut
        }

        guard try await waitForTarget(
            targetOrder: targetOrder,
            targetSpaceID: targetSpaceID,
            requestGeneration: requestGeneration
        ) else {
            throw SpaceNavigationError.timedOut
        }
    }

    func navigate(toSystemSpaceID targetSpaceID: Int) async throws {
        guard AXIsProcessTrusted() else {
            throw SpaceNavigationError.permissionDenied
        }
        guard let initialSnapshot = provider.snapshot(),
              let currentIndex = initialSnapshot.spaces.firstIndex(where: { $0.id == initialSnapshot.currentSpaceID }),
              let targetIndex = initialSnapshot.spaces.firstIndex(where: { $0.id == targetSpaceID }) else {
            throw SpaceNavigationError.invalidTarget
        }
        guard currentIndex != targetIndex else { return }

        generation += 1
        let requestGeneration = generation
        try await waitForMouseRelease(requestGeneration: requestGeneration)

        guard initialSnapshot.spaces[targetIndex].isFullscreen else {
            guard let targetOrder = initialSnapshot.regularSpaces.firstIndex(where: { $0.id == targetSpaceID })
                .map({ $0 + 1 }),
                  try await postConfiguredDesktopHotKey(
                    number: targetOrder,
                    requestGeneration: requestGeneration
                  ),
                  try await waitForSystemSpace(
                    targetSpaceID,
                    requestGeneration: requestGeneration
                  ) else {
                throw SpaceNavigationError.timedOut
            }
            return
        }

        let regularIndices = initialSnapshot.spaces.indices.filter {
            !initialSnapshot.spaces[$0].isFullscreen
        }
        guard let anchorIndex = regularIndices.min(by: {
            abs($0 - targetIndex) < abs($1 - targetIndex)
        }) else {
            throw SpaceNavigationError.mappingUnreliable
        }
        let anchorSpaceID = initialSnapshot.spaces[anchorIndex].id
        let anchorOrder = initialSnapshot.spaces[...anchorIndex].filter { !$0.isFullscreen }.count

        if initialSnapshot.currentSpaceID != anchorSpaceID {
            guard try await postConfiguredDesktopHotKey(
                number: anchorOrder,
                requestGeneration: requestGeneration
            ), try await waitForSystemSpace(
                anchorSpaceID,
                requestGeneration: requestGeneration
            ) else {
                throw SpaceNavigationError.timedOut
            }
            try await Task.sleep(for: Self.interStageDelay)
            try ensureCurrent(requestGeneration)
        }

        guard let anchoredSnapshot = provider.snapshot(),
              let anchoredIndex = anchoredSnapshot.spaces.firstIndex(where: { $0.id == anchorSpaceID }),
              let refreshedTargetIndex = anchoredSnapshot.spaces.firstIndex(where: { $0.id == targetSpaceID }) else {
            throw SpaceNavigationError.mappingUnreliable
        }
        let step = refreshedTargetIndex > anchoredIndex ? 1 : -1
        var expectedIndex = anchoredIndex

        while expectedIndex != refreshedTargetIndex {
            expectedIndex += step
            let expectedSpaceID = anchoredSnapshot.spaces[expectedIndex].id
            try await postAdjacentSpaceHotKey(step: step, requestGeneration: requestGeneration)
            guard try await waitForSystemSpace(
                expectedSpaceID,
                requestGeneration: requestGeneration
            ) else {
                throw SpaceNavigationError.timedOut
            }
            if expectedIndex != refreshedTargetIndex {
                try await Task.sleep(for: Self.interAdjacentStepDelay)
                try ensureCurrent(requestGeneration)
            }
        }
    }

    func cancel() {
        generation += 1
    }

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

    private func waitForTarget(
        targetOrder: Int,
        targetSpaceID: Int,
        requestGeneration: Int
    ) async throws -> Bool {
        for _ in 0..<Self.transitionPollCount {
            try await Task.sleep(for: Self.transitionPollInterval)
            try ensureCurrent(requestGeneration)
            guard let snapshot = provider.snapshot(),
                  snapshot.regularSpaces.indices.contains(targetOrder - 1),
                  snapshot.regularSpaces[targetOrder - 1].id == targetSpaceID else {
                continue
            }
            if snapshot.currentSpaceID == targetSpaceID {
                return true
            }
        }
        return false
    }

    private func waitForSystemSpace(
        _ targetSpaceID: Int,
        requestGeneration: Int
    ) async throws -> Bool {
        for _ in 0..<Self.transitionPollCount {
            try await Task.sleep(for: Self.transitionPollInterval)
            try ensureCurrent(requestGeneration)
            if provider.snapshot()?.currentSpaceID == targetSpaceID {
                return true
            }
        }
        return false
    }

    private func postAdjacentSpaceHotKey(step: Int, requestGeneration: Int) async throws {
        // Use macOS's configured Mission Control actions instead of fabricating
        // Control+Arrow flags. Arrow shortcuts carry an additional function-key
        // flag on current macOS versions (for example 0x840000), and dropping it
        // causes WindowServer to ignore the event.
        let hotKey = Int32(step > 0 ? 81 : 79)
        guard try await postConfiguredSymbolicHotKey(
            hotKey,
            requestGeneration: requestGeneration
        ) else {
            throw SpaceNavigationError.timedOut
        }
    }

    /// Posts the exact symbolic action registered for Desktop N. If macOS
    /// currently reports the action as disabled, temporarily enable only that
    /// action and restore its original state immediately after key-up.
    private func postConfiguredDesktopHotKey(
        number: Int,
        requestGeneration: Int
    ) async throws -> Bool {
        guard (1...16).contains(number) else {
            return false
        }

        return try await postConfiguredSymbolicHotKey(
            Int32(118 + number - 1),
            requestGeneration: requestGeneration
        )
    }

    private func postConfiguredSymbolicHotKey(
        _ hotKey: Int32,
        requestGeneration: Int
    ) async throws -> Bool {
        guard let symbols = SymbolicHotKeySymbols.shared else { return false }

        let wasEnabled = symbols.isEnabled(hotKey) != 0
        if !wasEnabled, symbols.setEnabled(hotKey, 1) != .success {
            return false
        }
        defer {
            if !wasEnabled {
                _ = symbols.setEnabled(hotKey, 0)
            }
        }

        var keyCode: CGKeyCode = 0
        var rawFlags: UInt32 = 0
        guard symbols.getValue(hotKey, nil, &keyCode, &rawFlags) == .success,
              keyCode != CGKeyCode.max,
              let keyDown = CGEvent(
                  keyboardEventSource: nil,
                  virtualKey: keyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: nil,
                  virtualKey: keyCode,
                  keyDown: false
              ) else {
            return false
        }

        let flags = CGEventFlags(rawValue: UInt64(rawFlags))
        keyDown.flags = flags
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: Self.keyPressDuration)
        keyUp.post(tap: .cghidEventTap)
        try? await Task.sleep(for: Self.postKeyDelay)
        try ensureCurrent(requestGeneration)
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
              let setEnabled = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else {
            return nil
        }
        self.handle = handle
        self.getValue = unsafeBitCast(getValue, to: GetValue.self)
        self.isEnabled = unsafeBitCast(isEnabled, to: IsEnabled.self)
        self.setEnabled = unsafeBitCast(setEnabled, to: SetEnabled.self)
    }

    deinit {
        dlclose(handle)
    }
}
