import AppKit
import Combine

@MainActor
final class SpaceObserver {
    private var spaceCancellable: AnyCancellable?
    private var topologyCancellable: AnyCancellable?

    init(
        onSpaceChange: @escaping @MainActor () -> Void,
        onTopologyPoll: @escaping @MainActor () -> Void
    ) {
        spaceCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { _ in onSpaceChange() }

        topologyCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { _ in onTopologyPoll() }
    }
}
