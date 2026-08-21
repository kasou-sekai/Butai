import AppKit
import ButaiCore
import Combine
import Foundation
import SwiftUI

struct OverlaySpaceItem: Identifiable {
    let id: Int
    let workspace: Workspace?
    let applicationBundleIdentifier: String?
    let applicationName: String?
    let isCurrent: Bool

    var isFullscreen: Bool { workspace == nil }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration = ButaiConfiguration.initial()
    @Published private(set) var isLoaded = false
    @Published var transientMessage: String?
    @Published private(set) var pendingTargetOrder: Int?
    @Published private(set) var needsInitialSetup = false
    @Published private(set) var spaceDetectionAvailable = false
    @Published private(set) var detectedSystemSpaceCount: Int?
    @Published private(set) var isCurrentSpaceFullscreen = false
    @Published private(set) var isPresetRunning = false
    @Published private(set) var lastPresetReport: PresetExecutionReport?

    let repository: ConfigurationRepository
    let navigator: any SpaceNavigating
    private let spaceProvider: any SystemSpaceProviding
    private let presetEngine: WindowPresetEngine
    private var saveTask: Task<Void, Never>?
    private var lastSystemSpaceSnapshot: SystemSpaceSnapshot?
    /// Runtime-only pointer to the profile currently projected into
    /// `configuration.workspaces` and `configuration.calibration`.
    private var activeDisplayIdentifier: String?

    init(
        repository: ConfigurationRepository = .defaultRepository(),
        spaceProvider: any SystemSpaceProviding = CGSSystemSpaceProvider(),
        navigator: (any SpaceNavigating)? = nil,
        presetEngine: WindowPresetEngine = WindowPresetEngine()
    ) {
        self.repository = repository
        self.spaceProvider = spaceProvider
        self.navigator = navigator ?? PrivateSpaceNavigator(provider: spaceProvider)
        self.presetEngine = presetEngine
        Task { await load() }
    }

    var workspaces: [Workspace] { configuration.workspaces }

    var currentWorkspace: Workspace? {
        guard spaceDetectionAvailable,
              activeDisplayIdentifier != nil,
              !isCurrentSpaceFullscreen else { return nil }
        guard let id = configuration.calibration.currentWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    var mappingIsReliable: Bool {
        configuration.calibration.reliability == .reliable
    }

    var displayWorkspace: Workspace? { currentWorkspace ?? workspaces.first }

    func applicationNames(for workspace: Workspace) -> [String]? {
        guard let snapshot = lastSystemSpaceSnapshot,
              snapshot.applicationInventoryAvailable,
              snapshot.regularSpaces.indices.contains(workspace.order - 1) else {
            return nil
        }
        return snapshot.regularSpaces[workspace.order - 1].applicationNames
    }

    var overlaySpaces: [OverlaySpaceItem] {
        guard let snapshot = lastSystemSpaceSnapshot else {
            return workspaces.map {
                OverlaySpaceItem(
                    id: $0.order,
                    workspace: $0,
                    applicationBundleIdentifier: nil,
                    applicationName: nil,
                    isCurrent: $0.id == currentWorkspace?.id
                )
            }
        }

        var regularOrder = 0
        return snapshot.spaces.compactMap { space in
            let workspace: Workspace?
            if space.isFullscreen {
                workspace = nil
            } else {
                regularOrder += 1
                workspace = workspaces.first(where: { $0.order == regularOrder })
                guard workspace != nil else { return nil }
            }
            return OverlaySpaceItem(
                id: space.id,
                workspace: workspace,
                applicationBundleIdentifier: space.applicationBundleIdentifier,
                applicationName: space.applicationName,
                isCurrent: space.id == snapshot.currentSpaceID
            )
        }
    }

    var systemSpaceIDs: [Int] {
        lastSystemSpaceSnapshot?.spaces.map(\.id) ?? []
    }

    var automaticOverlayWidth: Double {
        let currentItem = overlaySpaces.first(where: \.isCurrent)
        let name = currentItem?.workspace?.name
            ?? currentItem?.applicationName
            ?? "未校准"
        let width = ceil((name as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        ).width)
        return width + (!mappingIsReliable ? 34 : 16)
    }

    var automaticOverlayHeight: Double {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSStatusBar.system.thickness
        }
        let reservedTopHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return max(reservedTopHeight, NSStatusBar.system.thickness)
    }

    var currentPreset: Preset? { currentWorkspace?.presets.first }

    var adapterHealth: [AdapterHealth] { presetEngine.adapterHealth }

    func preset(for workspaceID: UUID) -> Preset? {
        workspaces.first(where: { $0.id == workspaceID })?.presets.first
    }

    private static let setupCompletionKey = "ButaiInitialSetupCompleteV2"

    func load() async {
        // A provider snapshot may arrive while the asynchronous load is in
        // flight. Force the first post-load synchronization to select the
        // loaded display profile instead of treating the old snapshot as
        // already synchronized.
        activeDisplayIdentifier = nil
        lastSystemSpaceSnapshot = nil
        do {
            if let saved = try await repository.load() {
                configuration = saved
                if migrateLegacyPresetItems() {
                    persist()
                }
            }
        } catch {
            transientMessage = "配置读取失败，已安全启动为空配置：\(error.localizedDescription)"
        }
        if synchronizeWithSystemSpaces() == nil {
            needsInitialSetup = !UserDefaults.standard.bool(forKey: Self.setupCompletionKey)
        }
        isLoaded = true
    }

    func setWorkspaceCount(_ requestedCount: Int) {
        guard !spaceDetectionAvailable else {
            transientMessage = "工作区数量由当前 macOS 普通桌面自动同步。"
            return
        }
        let count = min(max(requestedCount, 1), 9)
        guard count != configuration.workspaces.count else { return }

        if count > configuration.workspaces.count {
            for order in (configuration.workspaces.count + 1)...count {
                configuration.workspaces.append(Workspace(order: order, name: "工作区 \(order)"))
            }
        } else {
            configuration.workspaces.removeLast(configuration.workspaces.count - count)
        }
        configuration.normalizeWorkspaceOrder()
        if let currentID = configuration.calibration.currentWorkspaceID,
           !configuration.workspaces.contains(where: { $0.id == currentID }) {
            configuration.calibration.currentWorkspaceID = nil
        }
        configuration.calibration.reliability = .uncertain
        if !needsInitialSetup {
            transientMessage = "桌面数量已设为 \(count)，请确认当前所在桌面。"
        }
        persist()
    }

    func renameWorkspace(id: UUID, name: String) {
        guard let index = configuration.workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.workspaces[index].name = trimmed.isEmpty ? "工作区 \(index + 1)" : trimmed
        configuration.workspaces[index].updatedAt = .now
        persist()
    }

    func addWorkspace() {
        guard !spaceDetectionAvailable else {
            transientMessage = "请在 Mission Control 中添加桌面，Butai 会自动同步。"
            return
        }
        guard configuration.workspaces.count < 9 else { return }
        let order = configuration.workspaces.count + 1
        configuration.workspaces.append(Workspace(order: order, name: "工作区 \(order)"))
        configuration.normalizeWorkspaceOrder()
        markMappingUncertain(message: "工作区数量已改变，请重新校准。")
        persist()
    }

    func deleteWorkspaces(at offsets: IndexSet) {
        guard !spaceDetectionAvailable else {
            transientMessage = "请在 Mission Control 中删除桌面，Butai 会自动同步。"
            return
        }
        guard configuration.workspaces.count - offsets.count >= 1 else {
            transientMessage = "至少需要保留一个工作区。"
            return
        }
        let deletedCurrent = offsets.contains { index in
            configuration.workspaces[index].id == configuration.calibration.currentWorkspaceID
        }
        configuration.workspaces.remove(atOffsets: offsets)
        configuration.normalizeWorkspaceOrder()
        if deletedCurrent { configuration.calibration.currentWorkspaceID = nil }
        markMappingUncertain(message: "工作区顺序已改变，请重新校准。")
        persist()
    }

    func moveWorkspaces(from offsets: IndexSet, to destination: Int) {
        guard !spaceDetectionAvailable else {
            transientMessage = "工作区顺序跟随 Mission Control，不能在 Butai 中单独重排。"
            return
        }
        configuration.workspaces.move(fromOffsets: offsets, toOffset: destination)
        configuration.normalizeWorkspaceOrder()
        markMappingUncertain(message: "工作区顺序已改变，请重新校准。")
        persist()
    }

    func calibrateCurrent(as workspaceID: UUID) {
        guard configuration.workspaces.contains(where: { $0.id == workspaceID }) else { return }
        configuration.calibration = CalibrationState(
            reliability: .reliable,
            currentWorkspaceID: workspaceID,
            calibratedAt: .now,
            environmentSummary: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString); \(NSScreen.screens.count) display(s)"
        )
        transientMessage = "当前桌面已校准。"
        persist()
    }

    func completeInitialSetup() {
        guard mappingIsReliable || spaceDetectionAvailable else {
            transientMessage = "请先选择当前所在的桌面，再完成设置。"
            return
        }
        UserDefaults.standard.set(true, forKey: Self.setupCompletionKey)
        needsInitialSetup = false
        transientMessage = "初始设置完成，现在可以从浮窗或菜单栏切换工作区。"
    }

    func navigate(to workspace: Workspace) async {
        guard spaceDetectionAvailable else {
            transientMessage = "无法读取当前系统桌面；请重新启动 Butai 或检查系统版本。"
            return
        }
        if currentWorkspace == nil, isCurrentSpaceFullscreen,
           let targetSpaceID = systemSpaceID(for: workspace.order) {
            await navigate(toSystemSpaceID: targetSpaceID, targetRegularOrder: workspace.order)
            return
        }
        guard let current = currentWorkspace else {
            transientMessage = "无法读取当前系统桌面；请重新启动 Butai 或检查系统版本。"
            return
        }
        guard current.id != workspace.id else { return }

        transientMessage = nil
        pendingTargetOrder = workspace.order
        // Give OverlayController and WindowServer one frame to order the
        // cross-Space panels out before posting the first Space chord.
        try? await Task.sleep(for: .milliseconds(50))
        do {
            try await navigator.navigate(
                from: current.order,
                to: workspace.order,
                workspaceCount: workspaces.count
            )
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(125))
                if synchronizeWithSystemSpaces() == workspace.order {
                    pendingTargetOrder = nil
                    transientMessage = nil
                    return
                }
            }
            pendingTargetOrder = nil
            transientMessage = "macOS 没有完成这次桌面切换，请稍后重试。"
        } catch SpaceNavigationError.permissionDenied {
            pendingTargetOrder = nil
            transientMessage = "桌面切换需要辅助功能权限。请在系统设置中开启 Butai，返回后再次点击“切换”。"
        } catch SpaceNavigationError.timedOut {
            pendingTargetOrder = nil
            transientMessage = "macOS 没有响应目标桌面快捷键。请重试，或检查“键盘快捷键 → Mission Control”中的“切换到桌面”快捷键。"
        } catch SpaceNavigationError.mappingUnreliable {
            pendingTargetOrder = nil
            transientMessage = "桌面顺序正在变化，Butai 已停止切换以避免进入错误桌面。请稍后重试。"
        } catch SpaceNavigationError.interrupted {
            pendingTargetOrder = nil
            transientMessage = "这次桌面切换已被新的操作中断。"
        } catch {
            pendingTargetOrder = nil
            transientMessage = "无法执行桌面切换：\(error.localizedDescription)"
        }
    }

    func navigate(to item: OverlaySpaceItem) async {
        guard !item.isCurrent else { return }
        if let workspace = item.workspace {
            await navigate(to: workspace)
        } else {
            await navigate(toSystemSpaceID: item.id, targetRegularOrder: nil)
        }
    }

    private func navigate(toSystemSpaceID targetSpaceID: Int, targetRegularOrder: Int?) async {
        guard spaceDetectionAvailable,
              lastSystemSpaceSnapshot?.spaces.contains(where: { $0.id == targetSpaceID }) == true else {
            transientMessage = "无法读取目标 Space；请稍后重试。"
            return
        }
        guard lastSystemSpaceSnapshot?.currentSpaceID != targetSpaceID else { return }

        transientMessage = nil
        pendingTargetOrder = targetRegularOrder ?? 0
        try? await Task.sleep(for: .milliseconds(50))
        do {
            try await navigator.navigate(toSystemSpaceID: targetSpaceID)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(125))
                _ = synchronizeWithSystemSpaces()
                if lastSystemSpaceSnapshot?.currentSpaceID == targetSpaceID {
                    pendingTargetOrder = nil
                    transientMessage = nil
                    return
                }
            }
            pendingTargetOrder = nil
            transientMessage = "macOS 没有完成这次 Space 切换，请稍后重试。"
        } catch SpaceNavigationError.permissionDenied {
            pendingTargetOrder = nil
            transientMessage = "Space 切换需要辅助功能权限。请在系统设置中开启 Butai。"
        } catch SpaceNavigationError.interrupted {
            pendingTargetOrder = nil
            transientMessage = "这次 Space 切换已被新的操作中断。"
        } catch {
            pendingTargetOrder = nil
            transientMessage = "无法切换到目标 Space：\(error.localizedDescription)"
        }
    }

    func spaceDidChange() {
        guard isLoaded else { return }
        _ = synchronizeWithSystemSpaces()
        // Keep the overlay ordered out until the navigator has also repaired
        // the destination Space's front-application/menu-bar state. navigate
        // clears pendingTargetOrder after that confirmed handoff completes.
        transientMessage = nil
    }

    func refreshSystemSpaceTopology() {
        guard isLoaded else { return }
        _ = synchronizeWithSystemSpaces()
    }

    func displayEnvironmentDidChange() {
        guard isLoaded else { return }
        if synchronizeWithSystemSpaces() == nil {
            transientMessage = "显示器或桌面环境已改变，但暂时无法读取新的 Space 拓扑。"
        } else {
            transientMessage = nil
        }
    }

    func setOverlayVisible(_ visible: Bool) {
        configuration.settings.overlayVisible = visible
        persist()
    }

    func setFullscreenOverlayMode(_ mode: AppSettings.FullscreenOverlayMode) {
        configuration.settings.fullscreenOverlayMode = mode
        persist()
    }

    func setOverlayVerticalOffset(_ offset: Double) {
        configuration.settings.overlayVerticalOffset = min(max(offset, -10_000), 10_000)
        persist()
    }

    func setOverlayWidth(_ width: Double?) {
        configuration.settings.overlayWidth = width.map { min(max($0, 52), 4_000) }
        persist()
    }

    func setOverlayHeight(_ height: Double?) {
        configuration.settings.overlayHeight = height.map { min(max($0, 16), 240) }
        persist()
    }

    func resetOverlayPosition() {
        setOverlayVerticalOffset(0)
    }

    func captureCurrentWindowsAsPreset() async {
        guard CompatibilityChecker.accessibilityIsGranted else {
            transientMessage = "保存预设需要辅助功能权限，才能读取 Finder 文件夹和窗口信息。"
            CompatibilityChecker.requestAccessibility()
            return
        }
        guard let workspaceIndex = currentWorkspaceIndex else {
            transientMessage = "无法确定当前工作区，未保存预设。"
            return
        }
        let capture = await presetEngine.captureVisibleWindows()
        let items = capture.items
        guard !items.isEmpty else {
            transientMessage = capture.unresolvedFinderWindowCount > 0
                ? "无法读取 Finder 文件夹路径。请允许 Butai 控制 Finder 后重试。"
                : "当前桌面没有可保存的普通窗口。"
            return
        }

        let workspace = configuration.workspaces[workspaceIndex]
        let now = Date()
        if configuration.workspaces[workspaceIndex].presets.isEmpty {
            configuration.workspaces[workspaceIndex].presets = [
                Preset(
                    workspaceID: workspace.id,
                    name: "\(workspace.name)预设",
                    items: items,
                    updatedAt: now
                )
            ]
        } else {
            configuration.workspaces[workspaceIndex].presets[0].items = items
            configuration.workspaces[workspaceIndex].presets[0].updatedAt = now
        }
        configuration.workspaces[workspaceIndex].updatedAt = now
        lastPresetReport = nil
        if capture.unresolvedFinderWindowCount > 0 {
            transientMessage = "已保存 \(items.count) 个窗口；另有 \(capture.unresolvedFinderWindowCount) 个 Finder 窗口因缺少自动化权限未保存。"
        } else {
            transientMessage = "已从当前桌面保存 \(items.count) 个窗口到“\(workspace.name)”预设。"
        }
        persist()
    }

    func addPresetResource(workspaceID: UUID, kind: PresetItem.Kind, url: URL) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        var item: PresetItem
        switch kind {
        case .application:
            let bundle = Bundle(url: url)
            item = PresetItem(
                kind: .application,
                applicationBundleIdentifier: bundle?.bundleIdentifier,
                applicationPath: url.path,
                displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
            )
        case .folder, .finderFolder:
            let name = url.lastPathComponent
            item = PresetItem(
                kind: .finderFolder,
                applicationBundleIdentifier: "com.apple.finder",
                resourcePath: url.path,
                displayName: name,
                openPolicy: .newWindowRequired,
                matchRules: [
                    WindowMatchRule(kind: .resourcePath, value: url.path, weight: 40),
                    WindowMatchRule(kind: .titleExact, value: name, weight: 20)
                ]
            )
        case .file:
            item = PresetItem(kind: .file, resourcePath: url.path, displayName: url.lastPathComponent)
        case .vscodeFolder, .vscodeWorkspace:
            let vscode = preferredVSCodeApplication()
            item = PresetItem(
                kind: kind,
                applicationBundleIdentifier: vscode?.bundleIdentifier ?? "com.microsoft.VSCode",
                applicationPath: vscode?.url.path,
                resourcePath: url.path,
                displayName: url.lastPathComponent,
                openPolicy: .newWindowPreferred,
                matchRules: [WindowMatchRule(kind: .titlePrefix, value: url.deletingPathExtension().lastPathComponent, weight: 35)]
            )
        default:
            item = PresetItem(kind: kind, resourcePath: url.absoluteString, displayName: url.absoluteString)
        }
        appendPresetItem(item, workspaceIndex: workspaceIndex)
    }

    private func preferredVSCodeApplication() -> (bundleIdentifier: String, url: URL)? {
        let candidates = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            guard let identifier = $0.bundleIdentifier else { return false }
            return candidates.contains(identifier) && $0.bundleURL != nil
        }), let identifier = running.bundleIdentifier, let url = running.bundleURL {
            return (identifier, url)
        }
        for identifier in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return (identifier, url)
            }
        }
        return nil
    }

    func addPresetURL(workspaceID: UUID, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            transientMessage = "请输入有效的 http 或 https URL。"
            return
        }
        addPresetResource(workspaceID: workspaceID, kind: .url, url: url)
    }

    func createPreset(workspaceID: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              configuration.workspaces[workspaceIndex].presets.isEmpty else {
            return
        }
        let workspace = configuration.workspaces[workspaceIndex]
        configuration.workspaces[workspaceIndex].presets = [
            Preset(workspaceID: workspace.id, name: "(workspace.name)预设")
        ]
        configuration.workspaces[workspaceIndex].updatedAt = .now
        transientMessage = "已为 (workspace.name) 新建空白预设。"
        persist()
    }

    func deletePreset(workspaceID: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              !configuration.workspaces[workspaceIndex].presets.isEmpty else {
            return
        }
        configuration.workspaces[workspaceIndex].presets.removeAll()
        configuration.workspaces[workspaceIndex].updatedAt = .now
        lastPresetReport = nil
        transientMessage = "已删除 (configuration.workspaces[workspaceIndex].name) 的预设。"
        persist()
    }

    func addEdgeWindow(workspaceID: UUID, urlsText: String, profile: String) {
        let values = urlsText
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
        guard let first = values.first else {
            transientMessage = "请至少输入一个有效的 http 或 https URL。"
            return
        }
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = PresetItem(
            kind: .edgeWindow,
            applicationBundleIdentifier: "com.microsoft.edgemac",
            resourcePath: first,
            additionalResourcePaths: Array(values.dropFirst()),
            profileIdentifier: trimmedProfile.isEmpty ? nil : trimmedProfile,
            displayName: URL(string: first)?.host ?? "Edge 窗口",
            openPolicy: .newWindowRequired,
            matchRules: [WindowMatchRule(kind: .documentURL, value: first, weight: 45)]
        )
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        appendPresetItem(item, workspaceIndex: workspaceIndex)
    }

    func addChatGPTWindow(workspaceID: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let application = preferredChatGPTApplication()
        appendPresetItem(
            PresetItem(
                kind: .chatGPTWindow,
                applicationBundleIdentifier: application?.bundleIdentifier ?? "com.openai.codex",
                applicationPath: application?.url.path,
                displayName: "ChatGPT / Codex",
                openPolicy: .reusePreferred
            ),
            workspaceIndex: workspaceIndex
        )
    }

    private func preferredChatGPTApplication() -> (bundleIdentifier: String, url: URL)? {
        for identifier in ["com.openai.codex", "com.openai.chat"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return (identifier, url)
            }
        }
        return nil
    }

    @discardableResult
    private func migrateLegacyPresetItems() -> Bool {
        let chatGPTApplication = preferredChatGPTApplication()
        var changed = migrateLegacyPresetItems(
            in: &configuration.workspaces,
            chatGPTApplication: chatGPTApplication
        )
        for profileIndex in configuration.displayProfiles.indices {
            var profile = configuration.displayProfiles[profileIndex]
            if migrateLegacyPresetItems(
                in: &profile.workspaces,
                chatGPTApplication: chatGPTApplication
            ) {
                configuration.displayProfiles[profileIndex] = profile
                changed = true
            }
        }
        return changed
    }

    private func migrateLegacyPresetItems(
        in workspaces: inout [Workspace],
        chatGPTApplication: (bundleIdentifier: String, url: URL)?
    ) -> Bool {
        var changed = false
        for workspaceIndex in workspaces.indices {
            for presetIndex in workspaces[workspaceIndex].presets.indices {
                for itemIndex in workspaces[workspaceIndex].presets[presetIndex].items.indices {
                    var item = workspaces[workspaceIndex].presets[presetIndex].items[itemIndex]
                    var itemChanged = false
                    if item.kind == .chatGPTWindow, let application = chatGPTApplication,
                       (item.applicationBundleIdentifier != application.bundleIdentifier ||
                        item.applicationPath != application.url.path ||
                        item.openPolicy != .reusePreferred) {
                        item.applicationBundleIdentifier = application.bundleIdentifier
                        item.applicationPath = application.url.path
                        item.openPolicy = .reusePreferred
                        itemChanged = true
                    }
                    if item.kind == .folder, let path = item.resourcePath {
                        item.kind = .finderFolder
                        item.applicationBundleIdentifier = "com.apple.finder"
                        item.openPolicy = .newWindowRequired
                        item.matchRules = [WindowMatchRule(kind: .resourcePath, value: path, weight: 45)]
                        itemChanged = true
                    }
                    if itemChanged {
                        workspaces[workspaceIndex].presets[presetIndex].items[itemIndex] = item
                        changed = true
                    }
                }
            }
        }
        return changed
    }

    func setPresetItemEnabled(workspaceID: UUID, itemID: UUID, enabled: Bool) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              !configuration.workspaces[workspaceIndex].presets.isEmpty,
              let itemIndex = configuration.workspaces[workspaceIndex].presets[0].items
                .firstIndex(where: { $0.id == itemID }) else { return }
        configuration.workspaces[workspaceIndex].presets[0].items[itemIndex].enabled = enabled
        configuration.workspaces[workspaceIndex].presets[0].updatedAt = .now
        persist()
    }

    func deletePresetItems(workspaceID: UUID, at offsets: IndexSet) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              !configuration.workspaces[workspaceIndex].presets.isEmpty else { return }
        configuration.workspaces[workspaceIndex].presets[0].items.remove(atOffsets: offsets)
        for index in configuration.workspaces[workspaceIndex].presets[0].items.indices {
            configuration.workspaces[workspaceIndex].presets[0].items[index].sortOrder = index
        }
        configuration.workspaces[workspaceIndex].presets[0].updatedAt = .now
        persist()
    }

    func deletePresetItem(workspaceID: UUID, itemID: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              !configuration.workspaces[workspaceIndex].presets.isEmpty else {
            return
        }
        configuration.workspaces[workspaceIndex].presets[0].items.removeAll { $0.id == itemID }
        for index in configuration.workspaces[workspaceIndex].presets[0].items.indices {
            configuration.workspaces[workspaceIndex].presets[0].items[index].sortOrder = index
        }
        configuration.workspaces[workspaceIndex].presets[0].updatedAt = .now
        persist()
    }

    func completeCurrentPreset() async {
        await executeCurrentPreset(mode: .complete)
    }

    func restoreCurrentLayout() async {
        await executeCurrentPreset(mode: .restore)
    }

    private func markMappingUncertain(message: String) {
        configuration.calibration.reliability = .uncertain
        transientMessage = message
    }

    private var currentWorkspaceIndex: Int? {
        guard let id = configuration.calibration.currentWorkspaceID else { return nil }
        return configuration.workspaces.firstIndex { $0.id == id }
    }

    private func appendPresetItem(_ item: PresetItem, workspaceIndex: Int) {
        let workspace = configuration.workspaces[workspaceIndex]
        if configuration.workspaces[workspaceIndex].presets.isEmpty {
            configuration.workspaces[workspaceIndex].presets = [
                Preset(workspaceID: workspace.id, name: "\(workspace.name)预设")
            ]
        }
        var item = item
        item.sortOrder = configuration.workspaces[workspaceIndex].presets[0].items.count
        configuration.workspaces[workspaceIndex].presets[0].items.append(item)
        configuration.workspaces[workspaceIndex].presets[0].updatedAt = .now
        transientMessage = "已将“\(item.displayName)”加入 \(workspace.name) 预设。"
        persist()
    }

    private func executeCurrentPreset(mode: PresetExecutionReport.Mode) async {
        guard !isPresetRunning else { return }
        guard let preset = currentPreset else {
            transientMessage = "当前工作区还没有预设。请先保存当前窗口或添加项目。"
            return
        }
        isPresetRunning = true
        transientMessage = mode == .restore ? "正在补全项目并恢复布局…" : "正在补全预设…"
        let report = await presetEngine.execute(preset: preset, mode: mode)
        lastPresetReport = report
        isPresetRunning = false
        transientMessage = report.summary
    }

    @discardableResult
    private func synchronizeWithSystemSpaces() -> Int? {
        guard let snapshot = spaceProvider.snapshot() else {
            lastSystemSpaceSnapshot = nil
            activeDisplayIdentifier = nil
            spaceDetectionAvailable = false
            detectedSystemSpaceCount = nil
            isCurrentSpaceFullscreen = false
            configuration.calibration.reliability = .uncertain
            return nil
        }

        if snapshot == lastSystemSpaceSnapshot {
            return snapshot.currentRegularOrder
        }
        lastSystemSpaceSnapshot = snapshot

        let actualCount = snapshot.regularSpaces.count
        isCurrentSpaceFullscreen = snapshot.isCurrentSpaceFullscreen
        detectedSystemSpaceCount = actualCount
        spaceDetectionAvailable = true
        needsInitialSetup = false
        UserDefaults.standard.set(true, forKey: Self.setupCompletionKey)

        let supportedCount = min(max(actualCount, 1), 9)
        var changed = configuration.schemaVersion != 2
        configuration.schemaVersion = 2
        if activateDisplayProfile(
            displayIdentifier: snapshot.displayID,
            workspaceCount: supportedCount
        ) {
            changed = true
        }
        if configuration.workspaces.count != supportedCount {
            resizeWorkspaces(to: supportedCount)
            changed = true
        }

        guard let order = snapshot.currentRegularOrder,
              let workspace = configuration.workspaces.first(where: { $0.order == order }) else {
            configuration.calibration.reliability = snapshot.isCurrentSpaceFullscreen
                ? .reliable
                : .uncertain
            if actualCount > 9 {
                transientMessage = "检测到 \(actualCount) 个普通桌面；当前版本最多显示前 9 个。"
            }
            if changed { persist() }
            return nil
        }

        configuration.calibration = CalibrationState(
            reliability: .reliable,
            currentWorkspaceID: workspace.id,
            calibratedAt: .now,
            environmentSummary: "CGS runtime snapshot; \(actualCount) regular space(s)"
        )
        if changed { persist() }
        return order
    }

    private func resizeWorkspaces(to count: Int) {
        if let activeDisplayIdentifier,
           let profileIndex = configuration.displayProfiles.firstIndex(
               where: { $0.displayIdentifier == activeDisplayIdentifier }
           ) {
            configuration.workspaces = configuration.displayProfiles[profileIndex]
                .visibleWorkspaces(count: count)
            return
        }

        if count > configuration.workspaces.count {
            for order in (configuration.workspaces.count + 1)...count {
                configuration.workspaces.append(Workspace(order: order, name: "工作区 \(order)"))
            }
        } else if count < configuration.workspaces.count {
            configuration.workspaces.removeLast(configuration.workspaces.count - count)
        }
        configuration.normalizeWorkspaceOrder()
    }

    /// Switches the active projection to a display-specific profile. A new
    /// display always receives fresh default names; it never clones the
    /// currently active display's names or presets.
    private func activateDisplayProfile(
        displayIdentifier: String,
        workspaceCount: Int
    ) -> Bool {
        guard !displayIdentifier.isEmpty else { return false }
        guard activeDisplayIdentifier != displayIdentifier else { return false }

        saveActiveDisplayProfile()

        let profile: DisplayWorkspaceProfile
        if let profileIndex = configuration.displayProfiles.firstIndex(
            where: { $0.displayIdentifier == displayIdentifier }
        ) {
            profile = configuration.displayProfiles[profileIndex]
        } else if configuration.displayProfiles.isEmpty {
            // The old schema had one global workspace list. Use it only once
            // to seed the first precisely identified display; subsequent new
            // displays must start with their own profile.
            profile = DisplayWorkspaceProfile(
                displayIdentifier: displayIdentifier,
                workspaces: configuration.workspaces,
                calibration: configuration.calibration
            )
            configuration.displayProfiles.append(profile)
        } else {
            profile = DisplayWorkspaceProfile.new(
                displayIdentifier: displayIdentifier,
                workspaceCount: workspaceCount
            )
            configuration.displayProfiles.append(profile)
        }

        activeDisplayIdentifier = displayIdentifier
        configuration.workspaces = profile.visibleWorkspaces(count: workspaceCount)
        configuration.calibration = profile.calibration
        return true
    }

    /// Copies the active projection into its display profile while preserving
    /// workspaces beyond the current topology. This prevents a temporary
    /// display disconnect or a different desktop count from deleting saved
    /// names and presets.
    private func saveActiveDisplayProfile() {
        guard let activeDisplayIdentifier else { return }
        if let profileIndex = configuration.displayProfiles.firstIndex(
            where: { $0.displayIdentifier == activeDisplayIdentifier }
        ) {
            var profile = configuration.displayProfiles[profileIndex]
            profile.updateVisibleWorkspaces(configuration.workspaces)
            profile.calibration = configuration.calibration
            configuration.displayProfiles[profileIndex] = profile
        } else {
            configuration.displayProfiles.append(
                DisplayWorkspaceProfile(
                    displayIdentifier: activeDisplayIdentifier,
                    workspaces: configuration.workspaces,
                    calibration: configuration.calibration
                )
            )
        }
    }

    private func systemSpaceID(for regularOrder: Int) -> Int? {
        guard let snapshot = lastSystemSpaceSnapshot,
              snapshot.regularSpaces.indices.contains(regularOrder - 1) else { return nil }
        return snapshot.regularSpaces[regularOrder - 1].id
    }

    private func persist() {
        saveActiveDisplayProfile()
        let snapshot = configuration
        let previousSave = saveTask
        saveTask = Task {
            _ = await previousSave?.result
            do {
                try await repository.save(snapshot)
            } catch {
                transientMessage = "配置保存失败：\(error.localizedDescription)"
            }
        }
    }
}
