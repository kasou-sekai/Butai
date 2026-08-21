import Foundation

public enum SpaceNavigationError: Error, Equatable, Sendable {
    case permissionDenied
    case mappingUnreliable
    case invalidTarget
    case timedOut
    case interrupted
}

public protocol SpaceNavigating: Sendable {
    func navigate(from currentOrder: Int, to targetOrder: Int, workspaceCount: Int) async throws
    func navigate(toSystemSpaceID targetSpaceID: Int) async throws
    func cancel() async
}

public extension SpaceNavigating {
    func navigate(toSystemSpaceID targetSpaceID: Int) async throws {
        throw SpaceNavigationError.invalidTarget
    }
}

public struct NavigationIntent: Equatable, Sendable {
    public var currentOrder: Int
    public var targetOrder: Int
    public var step: Int { targetOrder == currentOrder ? 0 : (targetOrder > currentOrder ? 1 : -1) }
    public var stepCount: Int { abs(targetOrder - currentOrder) }

    public init(currentOrder: Int, targetOrder: Int, workspaceCount: Int) throws {
        guard (1...workspaceCount).contains(currentOrder),
              (1...workspaceCount).contains(targetOrder) else {
            throw SpaceNavigationError.invalidTarget
        }
        self.currentOrder = currentOrder
        self.targetOrder = targetOrder
    }
}
