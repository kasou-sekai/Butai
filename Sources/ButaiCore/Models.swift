import Foundation

public struct ButaiConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var workspaces: [Workspace]
    public var settings: AppSettings
    public var calibration: CalibrationState

    public init(
        schemaVersion: Int = 1,
        workspaces: [Workspace],
        settings: AppSettings = .init(),
        calibration: CalibrationState = .uncalibrated
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.settings = settings
        self.calibration = calibration
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
        case finderFolder, edgeWindow, command
    }

    public enum OpenPolicy: String, Codable, CaseIterable, Sendable {
        case reusePreferred, newWindowPreferred, newWindowRequired
    }

    public var id: UUID
    public var kind: Kind
    public var applicationBundleIdentifier: String?
    public var applicationPath: String?
    public var resourcePath: String?
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

    public var overlayVisible: Bool
    public var overlayHorizontalOffset: Double
    public var overlayVerticalOffset: Double
    public var feedbackDuration: Double
    public var capsLockShortcutsEnabled: Bool
    public var switchingAction: SwitchingAction

    public init(
        overlayVisible: Bool = true,
        overlayHorizontalOffset: Double = 0,
        overlayVerticalOffset: Double = 0,
        feedbackDuration: Double = 0.9,
        capsLockShortcutsEnabled: Bool = false,
        switchingAction: SwitchingAction = .nothing
    ) {
        self.overlayVisible = overlayVisible
        self.overlayHorizontalOffset = overlayHorizontalOffset
        self.overlayVerticalOffset = overlayVerticalOffset
        self.feedbackDuration = feedbackDuration
        self.capsLockShortcutsEnabled = capsLockShortcutsEnabled
        self.switchingAction = switchingAction
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
