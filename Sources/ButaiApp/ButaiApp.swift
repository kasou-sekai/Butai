import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var overlayController: OverlayController?
    private var spaceObserver: SpaceObserver?
    private var screenObserver: NSObjectProtocol?
    private var setupCancellable: AnyCancellable?
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        overlayController = OverlayController(model: model)
        spaceObserver = SpaceObserver(
            onSpaceChange: { [weak self] in
                self?.model.spaceDidChange()
                self?.overlayController?.activeSpaceDidChange()
            },
            onTopologyPoll: { [weak model = model] in model?.refreshSystemSpaceTopology() }
        )
        overlayController?.show()

        if !CompatibilityChecker.accessibilityIsGranted {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                CompatibilityChecker.requestAccessibility()
            }
        }

        setupCancellable = model.$needsInitialSetup
            .removeDuplicates()
            .filter { $0 }
            .sink { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    self.showSettingsWindow()
                }
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.overlayController?.reposition()
                self?.model.displayEnvironmentDidChange()
            }
        }
    }

    func showSettingsWindow() {
        let controller: NSWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            let content = SettingsView().environmentObject(model)
            let hostingController = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Butai 设置"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unified
            window.contentMinSize = NSSize(width: 760, height: 520)
            window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.isReleasedWhenClosed = false
            window.contentViewController = hostingController
            window.setFrameAutosaveName("ButaiSettingsWindow")

            controller = NSWindowController(window: window)
            settingsWindowController = controller
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@main
struct ButaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                model: delegate.model,
                openSettings: delegate.showSettingsWindow
            )
        } label: {
            Label(delegate.model.displayWorkspace?.name ?? "Butai", systemImage: "theatermasks")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { delegate.showSettingsWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        if let current = model.currentWorkspace {
            Text("当前：\(current.name)")
        } else {
            Text("当前工作区未确认")
        }

        Menu("切换工作区") {
            ForEach(model.workspaces) { workspace in
                Button("\(workspace.order). \(workspace.name)") {
                    Task { await model.navigate(to: workspace) }
                }
            }
        }

        Divider()
        Button("补全当前预设") {
            Task { await model.completeCurrentPreset() }
        }
        .disabled(model.currentPreset == nil || model.isPresetRunning)
        Button("恢复当前布局") {
            Task { await model.restoreCurrentLayout() }
        }
        .disabled(model.currentPreset == nil || model.isPresetRunning)
        Button("保存当前状态到预设") {
            Task { await model.captureCurrentWindowsAsPreset() }
        }
        .disabled(model.isPresetRunning)
        Divider()
        Button("设置…", systemImage: "gearshape") { openSettings() }
        Divider()
        Button("退出 Butai") { NSApplication.shared.terminate(nil) }
    }
}
