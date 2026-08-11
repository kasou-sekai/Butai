import Foundation

public struct PresetItemOutcome: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case ready
        case opened
        case restored
        case skipped
        case permissionDenied
        case applicationNotFound
        case openFailed
        case windowTimeout
        case lowConfidence
        case unsupported
        case unknownError
    }

    public let id: UUID
    public let itemID: UUID
    public let displayName: String
    public let status: Status
    public let message: String

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        displayName: String,
        status: Status,
        message: String
    ) {
        self.id = id
        self.itemID = itemID
        self.displayName = displayName
        self.status = status
        self.message = message
    }

    public var succeeded: Bool {
        switch status {
        case .ready, .opened, .restored, .skipped: true
        default: false
        }
    }
}

public struct PresetExecutionReport: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable { case complete, restore }

    public let presetID: UUID
    public let presetName: String
    public let mode: Mode
    public let outcomes: [PresetItemOutcome]
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        presetID: UUID,
        presetName: String,
        mode: Mode,
        outcomes: [PresetItemOutcome],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.presetID = presetID
        self.presetName = presetName
        self.mode = mode
        self.outcomes = outcomes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var successCount: Int { outcomes.count(where: \.succeeded) }
    public var issueCount: Int { outcomes.count - successCount }

    public var summary: String {
        let action = mode == .restore ? "已恢复" : "已补全"
        return "\(presetName)\(action)：\(successCount) 成功，\(issueCount) 需要处理"
    }
}

