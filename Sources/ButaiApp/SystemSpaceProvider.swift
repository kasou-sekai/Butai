import AppKit
import CoreGraphics
import Darwin
import Foundation

struct SystemSpace: Equatable, Sendable {
    let id: Int
    let uuid: String?
    let isFullscreen: Bool
    let applicationBundleIdentifier: String?
    let applicationName: String?
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

    var isCurrentSpaceFullscreen: Bool {
        spaces.first(where: { $0.id == currentSpaceID })?.isFullscreen ?? false
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
            let isFullscreen = raw["TileLayoutManager"] is [String: Any]
            let application = isFullscreen
                ? fullscreenApplication(in: id, connection: connection, symbols: symbols)
                    ?? applicationFromMetadata(in: raw)
                    ?? (id == currentID ? eligibleApplication(NSWorkspace.shared.frontmostApplication) : nil)
                : nil
            let bundleIdentifier = application?.bundleIdentifier
            return SystemSpace(
                id: id,
                uuid: raw["uuid"] as? String,
                isFullscreen: isFullscreen,
                applicationBundleIdentifier: bundleIdentifier,
                applicationName: application?.localizedName
                    ?? fullscreenTitle(in: raw)
                    ?? bundleIdentifier?.split(separator: ".").last.map(String.init)
                    ?? (isFullscreen ? "全屏应用" : nil)
            )
        }
        guard !spaces.isEmpty else { return nil }
        return SystemSpaceSnapshot(displayID: displayID, spaces: spaces, currentSpaceID: currentID)
    }

    private func fullscreenApplication(
        in spaceID: Int,
        connection: Int32,
        symbols: SkyLightSymbols
    ) -> NSRunningApplication? {
        guard let copyWindowsWithOptionsAndTags = symbols.copyWindowsWithOptionsAndTags else {
            return nil
        }
        var setTags = [UInt64](repeating: 0, count: 2)
        var clearTags = [UInt64](repeating: 0, count: 2)
        let windowIDs: [NSNumber]? = setTags.withUnsafeMutableBufferPointer { setBuffer in
            clearTags.withUnsafeMutableBufferPointer { clearBuffer in
                copyWindowsWithOptionsAndTags(
                    connection,
                    0,
                    [spaceID] as CFArray,
                    0x2,
                    setBuffer.baseAddress,
                    clearBuffer.baseAddress
                )?.takeRetainedValue() as? [NSNumber]
            }
        }
        guard let windowIDs, !windowIDs.isEmpty,
              let descriptions = CGWindowListCreateDescriptionFromArray(windowIDs as CFArray)
                as? [[CFString: Any]] else {
            return nil
        }

        return descriptions.lazy.compactMap { description -> NSRunningApplication? in
            guard (description[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let pid = (description[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  pid > 0 else { return nil }
            return eligibleApplication(NSRunningApplication(processIdentifier: pid))
        }.first
    }

    private func applicationFromMetadata(in value: Any) -> NSRunningApplication? {
        if let dictionary = value as? [String: Any] {
            for (key, candidate) in dictionary {
                let normalizedKey = key.lowercased().replacingOccurrences(of: "_", with: "")
                if normalizedKey.contains("pid") || normalizedKey.contains("processidentifier"),
                   let number = candidate as? NSNumber,
                   let application = eligibleApplication(
                       NSRunningApplication(processIdentifier: number.int32Value)
                   ) {
                    return application
                }
                if normalizedKey.contains("bundleidentifier") || normalizedKey == "bundleid",
                   let identifier = candidate as? String,
                   let application = NSRunningApplication.runningApplications(
                       withBundleIdentifier: identifier
                   ).first.flatMap(eligibleApplication) {
                    return application
                }
            }
            return dictionary.values.lazy.compactMap(applicationFromMetadata).first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap(applicationFromMetadata).first
        }
        return nil
    }

    private func fullscreenTitle(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["ApplicationName", "LocalizedName", "OwnerName", "appName"]
            for key in preferredKeys {
                if let title = dictionary[key] as? String, !title.isEmpty { return title }
            }
            return dictionary.values.lazy.compactMap(fullscreenTitle).first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap(fullscreenTitle).first
        }
        return nil
    }

    private func eligibleApplication(_ application: NSRunningApplication?) -> NSRunningApplication? {
        guard let application,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              application.bundleIdentifier != "com.apple.dock" else { return nil }
        return application
    }
}

private final class SkyLightSymbols: @unchecked Sendable {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopyActiveMenuBarDisplayIdentifier = @convention(c) (Int32) -> Unmanaged<CFString>?
    typealias CopyWindowsWithOptionsAndTags = @convention(c) (
        Int32,
        Int32,
        CFArray,
        UInt32,
        UnsafeMutablePointer<UInt64>?,
        UnsafeMutablePointer<UInt64>?
    ) -> Unmanaged<CFArray>?

    static let shared: SkyLightSymbols? = SkyLightSymbols()

    let defaultConnection: DefaultConnection
    let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    let copyActiveMenuBarDisplayIdentifier: CopyActiveMenuBarDisplayIdentifier
    let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTags?
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
        copyWindowsWithOptionsAndTags = dlsym(handle, "CGSCopyWindowsWithOptionsAndTags").map {
            unsafeBitCast($0, to: CopyWindowsWithOptionsAndTags.self)
        }
    }

    deinit { dlclose(handle) }
}
