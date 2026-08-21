import Foundation

public struct ButaiConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var workspaces: [Workspace]
    public var settings: AppSettings
    public var calibration: CalibrationState
    /// Workspace data is kept separately for every display. `workspaces` and
    /// `calibration` remain the active-display projection for compatibility
    /// with the current UI and command surface.
    public var displayProfiles: [DisplayWorkspaceProfile]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workspaces
        case settings
        case calibration
        case displayProfiles
    }

    public init(
        schemaVersion: Int = 2,
        workspaces: [Workspace],
        settings: AppSettings = .init(),
        calibration: CalibrationState = .uncalibrated,
        displayProfiles: [DisplayWorkspaceProfile] = []
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.settings = settings
        self.calibration = calibration
        self.displayProfiles = displayProfiles
        normalizeWorkspaceOrder()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? .init()
        calibration = try container.decodeIfPresent(CalibrationState.self, forKey: .calibration)
            ?? .uncalibrated
        // This is intentionally optional so configurations written before
        // display profiles existed migrate without losing their workspace data.
        displayProfiles = try container.decodeIfPresent(
            [DisplayWorkspaceProfile].self,
            forKey: .displayProfiles
        ) ?? []
        normalizeWorkspaceOrder()
    }

    public static func initial(workspaceCount: Int = 4) -> ButaiConfiguration {
        let count = min(max(workspaceCount, 1), 9)
        return ButaiConfiguration(
            workspaces: (1...count).map { Workspace(order: $0, name: "工作区 \($0)") }
        )
    }

    public mutating func normalizeWorkspaceOrder() {
        workspaces = Array(workspaces.prefix(9))
        for index in workspaces.indices {
            workspaces[index].order = index + 1
            workspaces[index].shortcutIndex = index + 1
        }
        for index in displayProfiles.indices {
            displayProfiles[index].normalizeWorkspaceOrder()
        }
    }
}

/// Persisted workspace and calibration state for one physical display.
///
/// The display identifier is deliberately the profile key. A profile is never
/// removed when a display disappears, so reconnecting that display restores
/// its names and presets instead of inheriting another display's state.
public struct DisplayWorkspaceProfile: Codable, Equatable, Identifiable, Sendable {
    public var displayIdentifier: String
    public var workspaces: [Workspace]
    public var calibration: CalibrationState

    public var id: String { displayIdentifier }

    public init(
        displayIdentifier: String,
        workspaces: [Workspace],
        calibration: CalibrationState = .uncalibrated
    ) {
        self.displayIdentifier = displayIdentifier
        self.workspaces = workspaces
        self.calibration = calibration
        normalizeWorkspaceOrder()
    }

    public static func new(displayIdentifier: String, workspaceCount: Int) -> DisplayWorkspaceProfile {
        let count = min(max(workspaceCount, 1), 9)
        return DisplayWorkspaceProfile(
            displayIdentifier: displayIdentifier,
            workspaces: (1...count).map { Workspace(order: $0, name: "工作区 \($0)") }
        )
    }

    /// Returns the workspaces visible in the current display topology while
    /// retaining any extra saved workspaces for later reconnection.
    public func visibleWorkspaces(count: Int) -> [Workspace] {
        let clampedCount = min(max(count, 1), 9)
        var visible = Array(workspaces.prefix(clampedCount))
        if visible.count < clampedCount {
            visible.append(contentsOf: ((visible.count + 1)...clampedCount).map {
                Workspace(order: $0, name: "工作区 \($0)")
            })
        }
        var result = visible
        for index in result.indices {
            result[index].order = index + 1
            result[index].shortcutIndex = index + 1
        }
        return result
    }

    /// Merges the active projection back into this profile without deleting
    /// saved workspaces that are temporarily absent from the display.
    public mutating func updateVisibleWorkspaces(_ visibleWorkspaces: [Workspace]) {
        var stored = workspaces
        if stored.count < visibleWorkspaces.count {
            stored.append(contentsOf: visibleWorkspaces.dropFirst(stored.count))
        }
        for index in visibleWorkspaces.indices {
            stored[index] = visibleWorkspaces[index]
        }
        workspaces = Array(stored.prefix(9))
        normalizeWorkspaceOrder()
    }

    fileprivate mutating func normalizeWorkspaceOrder() {
        workspaces = Array(workspaces.prefix(9))
        for index in workspaces.indices {
            workspaces[index].order = index + 1
            workspaces[index].shortcutIndex = index + 1
        }
    }
}

public struct Workspace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var order: Int
    public var name: String
    public var colorHex: String?
    public var symbol: String?
    public var shortcutIndex: Int?
    public var presets: [Preset]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        order: Int,
        name: String,
        colorHex: String? = nil,
        symbol: String? = nil,
        shortcutIndex: Int? = nil,
        presets: [Preset] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.order = order
        self.name = name
        self.colorHex = colorHex
        self.symbol = symbol
        self.shortcutIndex = shortcutIndex ?? order
        self.presets = presets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Preset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    public var name: String
    public var items: [PresetItem]
    public var layoutVersion: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        name: String,
        items: [PresetItem] = [],
        layoutVersion: Int = 1,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.items = items
        self.layoutVersion = layoutVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PresetItem: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case application, file, folder, url, vscodeFolder, vscodeWorkspace
        case finderFolder, edgeWindow, chatGPTWindow, command
    }

    public enum OpenPolicy: String, Codable, CaseIterable, Sendable {
        case reusePreferred, newWindowPreferred, newWindowRequired
    }

    public var id: UUID
    public var kind: Kind
    public var applicationBundleIdentifier: String?
    public var applicationPath: String?
    public var resourcePath: String?
    public var additionalResourcePaths: [String]?
    public var profileIdentifier: String?
    public var displayName: String
    public var openPolicy: OpenPolicy
    public var matchRules: [WindowMatchRule]
    public var windowLayout: WindowLayout?
    public var timeoutSeconds: Double
    public var enabled: Bool
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        applicationBundleIdentifier: String? = nil,
        applicationPath: String? = nil,
        resourcePath: String? = nil,
        additionalResourcePaths: [String]? = nil,
        profileIdentifier: String? = nil,
        displayName: String,
        openPolicy: OpenPolicy = .reusePreferred,
        matchRules: [WindowMatchRule] = [],
        windowLayout: WindowLayout? = nil,
        timeoutSeconds: Double = 8,
        enabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationPath = applicationPath
        self.resourcePath = resourcePath
        self.additionalResourcePaths = additionalResourcePaths
        self.profileIdentifier = profileIdentifier
        self.displayName = displayName
        self.openPolicy = openPolicy
        self.matchRules = matchRules
        self.windowLayout = windowLayout
        self.timeoutSeconds = timeoutSeconds
        self.enabled = enabled
        self.sortOrder = sortOrder
    }
}

public struct WindowMatchRule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bundleIdentifier, titleExact, titlePrefix, titleSuffix, titleRegex
        case documentURL, resourcePath, role, subrole
    }

    public var kind: Kind
    public var value: String
    public var weight: Int

    public init(kind: Kind, value: String, weight: Int) {
        self.kind = kind
        self.value = value
        self.weight = weight
    }
}

public struct WindowLayout: Codable, Equatable, Sendable {
    public var screenIdentifier: String?
    public var normalizedX: Double
    public var normalizedY: Double
    public var normalizedWidth: Double
    public var normalizedHeight: Double
    public var minimized: Bool
    public var bringToFront: Bool

    public init(
        screenIdentifier: String? = nil,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        minimized: Bool = false,
        bringToFront: Bool = false
    ) {
        self.screenIdentifier = screenIdentifier
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.minimized = minimized
        self.bringToFront = bringToFront
    }

    public func clamped(minimumFraction: Double = 0.08) -> WindowLayout {
        var copy = self
        copy.normalizedWidth = min(max(normalizedWidth, minimumFraction), 1)
        copy.normalizedHeight = min(max(normalizedHeight, minimumFraction), 1)
        copy.normalizedX = min(max(normalizedX, 0), 1 - copy.normalizedWidth)
        copy.normalizedY = min(max(normalizedY, 0), 1 - copy.normalizedHeight)
        return copy
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public enum SwitchingAction: String, Codable, Sendable {
        case nothing, checkPreset, completePreset
    }

    public enum FullscreenOverlayMode: String, Codable, Sendable, CaseIterable {
        case hidden
        case revealAtTop
        case always
    }

    public var overlayVisible: Bool
    public let overlayHorizontalOffset: Double
    public var overlayVerticalOffset: Double
    public var overlayWidth: Double?
    public var overlayHeight: Double?
    public var fullscreenOverlayMode: FullscreenOverlayMode?
    public var feedbackDuration: Double
    public var capsLockShortcutsEnabled: Bool
    public var switchingAction: SwitchingAction

    private enum CodingKeys: String, CodingKey {
        case overlayVisible
        case overlayHorizontalOffset
        case overlayVerticalOffset
        case overlayWidth
        case overlayHeight
        case fullscreenOverlayMode
        case feedbackDuration
        case capsLockShortcutsEnabled
        case switchingAction
    }

    public init(
        overlayVisible: Bool = true,
        overlayHorizontalOffset: Double = 0,
        overlayVerticalOffset: Double = 0,
        overlayWidth: Double? = nil,
        overlayHeight: Double? = nil,
        fullscreenOverlayMode: FullscreenOverlayMode? = .always,
        feedbackDuration: Double = 0.9,
        capsLockShortcutsEnabled: Bool = false,
        switchingAction: SwitchingAction = .nothing
    ) {
        self.overlayVisible = overlayVisible
        // Horizontal positioning is intentionally fixed at the screen
        // center. Keep the stored field for backward-compatible decoding.
        self.overlayHorizontalOffset = 0
        self.overlayVerticalOffset = overlayVerticalOffset
        self.overlayWidth = overlayWidth
        self.overlayHeight = overlayHeight
        self.fullscreenOverlayMode = fullscreenOverlayMode
        self.feedbackDuration = feedbackDuration
        self.capsLockShortcutsEnabled = capsLockShortcutsEnabled
        self.switchingAction = switchingAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overlayVisible = try container.decodeIfPresent(Bool.self, forKey: .overlayVisible) ?? true
        // Ignore historical values so an old configuration cannot move the
        // overlay horizontally after an update.
        overlayHorizontalOffset = 0
        overlayVerticalOffset = try container.decodeIfPresent(
            Double.self,
            forKey: .overlayVerticalOffset
        ) ?? 0
        overlayWidth = try container.decodeIfPresent(Double.self, forKey: .overlayWidth)
        overlayHeight = try container.decodeIfPresent(Double.self, forKey: .overlayHeight)
        fullscreenOverlayMode = try container.decodeIfPresent(
            FullscreenOverlayMode.self,
            forKey: .fullscreenOverlayMode
        ) ?? .always
        feedbackDuration = try container.decodeIfPresent(Double.self, forKey: .feedbackDuration) ?? 0.9
        capsLockShortcutsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .capsLockShortcutsEnabled
        ) ?? false
        switchingAction = try container.decodeIfPresent(
            SwitchingAction.self,
            forKey: .switchingAction
        ) ?? .nothing
    }
}

public struct CalibrationState: Codable, Equatable, Sendable {
    public enum Reliability: String, Codable, Sendable {
        case uncalibrated, reliable, uncertain
    }

    public var reliability: Reliability
    public var currentWorkspaceID: UUID?
    public var calibratedAt: Date?
    public var environmentSummary: String?

    public static let uncalibrated = CalibrationState(reliability: .uncalibrated)

    public init(
        reliability: Reliability,
        currentWorkspaceID: UUID? = nil,
        calibratedAt: Date? = nil,
        environmentSummary: String? = nil
    ) {
        self.reliability = reliability
        self.currentWorkspaceID = currentWorkspaceID
        self.calibratedAt = calibratedAt
        self.environmentSummary = environmentSummary
    }
}
