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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        overlayController = OverlayController(model: model)
        spaceObserver = SpaceObserver { [weak model = model] in model?.spaceDidChange() }
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
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    _ = NSApplication.shared.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
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
}

@main
struct ButaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            Label(delegate.model.displayWorkspace?.name ?? "Butai", systemImage: "theatermasks")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let current = model.currentWorkspace {
            Text("当前：\(current.name)")
        } else {
            Text("当前工作区未确认")
        }

        if let message = model.transientMessage {
            Text(message)
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
            model.captureCurrentWindowsAsPreset()
        }
        .disabled(model.isPresetRunning)
        Divider()
        Menu("将当前桌面标记为") {
            ForEach(model.workspaces) { workspace in
                Button("\(workspace.order). \(workspace.name)") {
                    model.calibrateCurrent(as: workspace.id)
                }
            }
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 Butai") { NSApplication.shared.terminate(nil) }
    }
}
