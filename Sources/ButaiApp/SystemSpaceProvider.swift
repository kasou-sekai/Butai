import AppKit
import CoreGraphics
import Darwin
import Foundation

struct SystemSpace: Equatable, Sendable {
    let id: Int
    let uuid: String?
    let isFullscreen: Bool
}

struct SystemSpaceSnapshot: Equatable, Sendable {
    let displayID: String
    let spaces: [SystemSpace]
    let currentSpaceID: Int

    var regularSpaces: [SystemSpace] { spaces.filter { !$0.isFullscreen } }

    var currentRegularOrder: Int? {
        guard let index = regularSpaces.firstIndex(where: { $0.id == currentSpaceID }) else { return nil }
        return index + 1
    }

    func fullIndex(forRegularOrder order: Int) -> Int? {
        guard regularSpaces.indices.contains(order - 1) else { return nil }
        let id = regularSpaces[order - 1].id
        return spaces.firstIndex { $0.id == id }
    }
}

protocol SystemSpaceProviding: Sendable {
    func snapshot() -> SystemSpaceSnapshot?
}

/// Runtime-only adapter for the private CGS read APIs used by established
/// open-source utilities such as WhichSpace. IDs never leave this process or
/// enter Butai's persisted workspace model.
struct CGSSystemSpaceProvider: SystemSpaceProviding {
    func snapshot() -> SystemSpaceSnapshot? {
        guard let symbols = SkyLightSymbols.shared else { return nil }
        let connection = symbols.defaultConnection()
        guard let rawDisplays = symbols.copyManagedDisplaySpaces(connection)?.takeRetainedValue()
            as? [[String: Any]], !rawDisplays.isEmpty else { return nil }

        let activeDisplay = symbols.copyActiveMenuBarDisplayIdentifier(connection)?
            .takeRetainedValue() as String?
        let display = rawDisplays.first { ($0["Display Identifier"] as? String) == activeDisplay }
            ?? rawDisplays.first
        guard let display,
              let displayID = display["Display Identifier"] as? String,
              let rawSpaces = display["Spaces"] as? [[String: Any]],
              let current = display["Current Space"] as? [String: Any],
              let currentID = current["ManagedSpaceID"] as? Int else { return nil }

        let spaces = rawSpaces.compactMap { raw -> SystemSpace? in
            guard let id = raw["ManagedSpaceID"] as? Int else { return nil }
            return SystemSpace(
                id: id,
                uuid: raw["uuid"] as? String,
                isFullscreen: raw["TileLayoutManager"] is [String: Any]
            )
        }
        guard !spaces.isEmpty else { return nil }
        return SystemSpaceSnapshot(displayID: displayID, spaces: spaces, currentSpaceID: currentID)
    }
}

private final class SkyLightSymbols: @unchecked Sendable {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyActiveMenuBarDisplayIdentifier = @convention(c) (Int32) -> Unmanaged<CFString>?

    static let shared: SkyLightSymbols? = SkyLightSymbols()

    let defaultConnection: DefaultConnection
    let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    let copyActiveMenuBarDisplayIdentifier: CopyActiveMenuBarDisplayIdentifier
    private let handle: UnsafeMutableRawPointer

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let defaultConnectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let managedSpacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
              let activeDisplaySymbol = dlsym(handle, "CGSCopyActiveMenuBarDisplayIdentifier") else {
            return nil
        }
        self.handle = handle
        defaultConnection = unsafeBitCast(defaultConnectionSymbol, to: DefaultConnection.self)
        copyManagedDisplaySpaces = unsafeBitCast(managedSpacesSymbol, to: CopyManagedDisplaySpaces.self)
        copyActiveMenuBarDisplayIdentifier = unsafeBitCast(
            activeDisplaySymbol,
            to: CopyActiveMenuBarDisplayIdentifier.self
        )
    }

    deinit { dlclose(handle) }
}
