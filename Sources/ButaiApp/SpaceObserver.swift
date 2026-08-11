import AppKit
import Combine

@MainActor
final class SpaceObserver {
    private var cancellable: AnyCancellable?

    init(onSpaceChange: @escaping @MainActor () -> Void) {
        cancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { _ in onSpaceChange() }
    }
}
