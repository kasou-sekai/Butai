import ApplicationServices
import AppKit
import ButaiCore
import CoreGraphics
import Darwin
import Foundation

/// Switches native Spaces by asking Dock's Mission Control accessibility UI
/// to press the target Space button. Dock performs the real transition, so its
/// front-application, menu-bar, and compositor state remain synchronized.
/// This requires Accessibility permission but neither symbolic shortcuts nor
/// a disabled-SIP scripting addition.
actor PrivateSpaceNavigator: SpaceNavigating {
    private static let mouseReleasePollCount = 60
    private static let missionControlPollCount = 80
    private static let transitionPollCount = 40
    private static let pollInterval = Duration.milliseconds(25)
    private static let transitionPollInterval = Duration.milliseconds(50)
    private static let missionControlSettleDelay = Duration.milliseconds(300)

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
        guard let targetIndex = snapshot.spaces.firstIndex(
            where: { $0.id == targetSpaceID }
        ) else {
            throw SpaceNavigationError.mappingUnreliable
        }

        guard try await pressMissionControlSpace(
            targetIndex: targetIndex,
            displayIdentifier: snapshot.displayID,
            requestGeneration: requestGeneration
        ) else {
            closeMissionControlIfVisible()
            throw SpaceNavigationError.timedOut
        }

        if try await waitForTarget(
            targetOrder: targetOrder,
            requestGeneration: requestGeneration
        ) {
            return
        }
        closeMissionControlIfVisible()
        throw SpaceNavigationError.timedOut
    }

    func cancel() {
        generation += 1
        closeMissionControlIfVisible()
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
        requestGeneration: Int
    ) async throws -> Bool {
        for _ in 0..<Self.transitionPollCount {
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

    /// Mirrors hs.spaces.gotoSpace: open Mission Control through Dock, wait
    /// until its accessibility hierarchy exists, locate mc.spaces.list for the
    /// target display, then AXPress the child at the target Space's full index.
    private func pressMissionControlSpace(
        targetIndex: Int,
        displayIdentifier: String,
        requestGeneration: Int
    ) async throws -> Bool {
        guard let dockRoot = dockAccessibilityElement(),
              let symbols = DockSymbols.shared else {
            return false
        }

        let wasVisible = missionControlGroup(in: dockRoot) != nil
        if !wasVisible {
            guard symbols.toggleMissionControl() == .success else { return false }
            try await Task.sleep(for: Self.missionControlSettleDelay)
        }

        let screenID = await MainActor.run {
            screenID(matching: displayIdentifier)
        }

        for _ in 0..<Self.missionControlPollCount {
            try ensureCurrent(requestGeneration)
            if let list = missionControlSpacesList(in: dockRoot, screenID: screenID),
               let children = accessibilityChildren(of: list),
               children.indices.contains(targetIndex) {
                return AXUIElementPerformAction(
                    children[targetIndex],
                    kAXPressAction as CFString
                ) == .success
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        return false
    }

    private func dockAccessibilityElement() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            return nil
        }
        return AXUIElementCreateApplication(dock.processIdentifier)
    }

    private func closeMissionControlIfVisible() {
        guard let dockRoot = dockAccessibilityElement(),
              missionControlGroup(in: dockRoot) != nil else {
            return
        }
        _ = DockSymbols.shared?.toggleMissionControl()
    }

    private func missionControlSpacesList(
        in dockRoot: AXUIElement,
        screenID: CGDirectDisplayID?
    ) -> AXUIElement? {
        guard let missionControl = missionControlGroup(in: dockRoot) else {
            return nil
        }
        let displays = descendants(
            of: missionControl,
            matchingIdentifier: "mc.display",
            maximumDepth: 4
        )
        let display = displays.first { element in
            guard let screenID else { return false }
            return accessibilityNumber(
                of: element,
                attribute: "AXDisplayID" as CFString
            )?.uint32Value == screenID
        } ?? displays.first
        guard let display else { return nil }

        return firstDescendant(
            of: display,
            matchingIdentifier: "mc.spaces.list",
            maximumDepth: 4
        )
    }

    private func missionControlGroup(in dockRoot: AXUIElement) -> AXUIElement? {
        firstDescendant(
            of: dockRoot,
            matchingIdentifier: "mc",
            maximumDepth: 3
        )
    }

    private func firstDescendant(
        of element: AXUIElement,
        matchingIdentifier identifier: String,
        maximumDepth: Int
    ) -> AXUIElement? {
        descendants(
            of: element,
            matchingIdentifier: identifier,
            maximumDepth: maximumDepth
        ).first
    }

    private func descendants(
        of element: AXUIElement,
        matchingIdentifier identifier: String,
        maximumDepth: Int
    ) -> [AXUIElement] {
        if accessibilityString(
            of: element,
            attribute: kAXIdentifierAttribute as CFString
        ) == identifier {
            return [element]
        }
        guard maximumDepth > 0,
              let children = accessibilityChildren(of: element) else {
            return []
        }
        return children.flatMap {
            descendants(
                of: $0,
                matchingIdentifier: identifier,
                maximumDepth: maximumDepth - 1
            )
        }
    }

    private func accessibilityChildren(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func accessibilityString(
        of element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func accessibilityNumber(
        of element: AXUIElement,
        attribute: CFString
    ) -> NSNumber? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? NSNumber
    }

    @MainActor
    private func screenID(matching displayIdentifier: String) -> CGDirectDisplayID? {
        if displayIdentifier == "Main" {
            return CGMainDisplayID()
        }
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuid) as String? else {
                continue
            }
            if uuidString.caseInsensitiveCompare(displayIdentifier) == .orderedSame {
                return displayID
            }
        }
        return nil
    }

    private func ensureCurrent(_ requestGeneration: Int) throws {
        guard generation == requestGeneration, !Task.isCancelled else {
            throw SpaceNavigationError.interrupted
        }
    }
}

private final class DockSymbols: @unchecked Sendable {
    typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> CGError

    static let shared: DockSymbols? = DockSymbols()

    private let sendNotification: CoreDockSendNotification
    private let handle: UnsafeMutableRawPointer

    private init?() {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification") else {
            return nil
        }
        self.handle = handle
        sendNotification = unsafeBitCast(symbol, to: CoreDockSendNotification.self)
    }

    func toggleMissionControl() -> CGError {
        sendNotification("com.apple.expose.awake" as CFString, 0)
    }

    deinit { dlclose(handle) }
}
