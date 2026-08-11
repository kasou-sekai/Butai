import AppKit
import ButaiCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration = ButaiConfiguration.initial()
    @Published private(set) var isLoaded = false
    @Published var transientMessage: String?
    @Published private(set) var pendingTargetOrder: Int?
    @Published private(set) var needsInitialSetup = false
    @Published private(set) var spaceDetectionAvailable = false
    @Published private(set) var detectedSystemSpaceCount: Int?

    let repository: ConfigurationRepository
    let navigator: any SpaceNavigating
    private let spaceProvider: any SystemSpaceProviding

    init(
        repository: ConfigurationRepository = .defaultRepository(),
        spaceProvider: any SystemSpaceProviding = CGSSystemSpaceProvider(),
        navigator: (any SpaceNavigating)? = nil
    ) {
        self.repository = repository
        self.spaceProvider = spaceProvider
        self.navigator = navigator ?? PrivateSpaceNavigator(provider: spaceProvider)
        Task { await load() }
    }

    var workspaces: [Workspace] { configuration.workspaces }

    var currentWorkspace: Workspace? {
        guard let id = configuration.calibration.currentWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    var mappingIsReliable: Bool {
        configuration.calibration.reliability == .reliable
    }

    var displayWorkspace: Workspace? { currentWorkspace ?? workspaces.first }

    private static let setupCompletionKey = "ButaiInitialSetupCompleteV2"

    func load() async {
        do {
            if let saved = try await repository.load() {
                configuration = saved
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
        guard spaceDetectionAvailable, let current = currentWorkspace else {
            transientMessage = "无法读取当前系统桌面；请重新启动 Butai 或检查系统版本。"
            return
        }
        guard current.id != workspace.id else { return }

        transientMessage = nil
        pendingTargetOrder = workspace.order
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
        } catch {
            pendingTargetOrder = nil
            transientMessage = "无法执行桌面切换：\(error.localizedDescription)"
        }
    }

    func spaceDidChange() {
        let actualOrder = synchronizeWithSystemSpaces()
        if actualOrder == pendingTargetOrder {
            pendingTargetOrder = nil
        }
        transientMessage = nil
    }

    func displayEnvironmentDidChange() {
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

    func setOverlayOffsets(horizontal: Double, vertical: Double) {
        configuration.settings.overlayHorizontalOffset = horizontal
        configuration.settings.overlayVerticalOffset = vertical
        persist()
    }

    func resetOverlayPosition() {
        setOverlayOffsets(horizontal: 0, vertical: 0)
    }

    func showPrototypeMessage(_ action: String) {
        transientMessage = "“\(action)”将在预设执行阶段接入；当前首版已保留安全执行边界。"
    }

    private func markMappingUncertain(message: String) {
        configuration.calibration.reliability = .uncertain
        transientMessage = message
    }

    @discardableResult
    private func synchronizeWithSystemSpaces() -> Int? {
        guard let snapshot = spaceProvider.snapshot() else {
            spaceDetectionAvailable = false
            detectedSystemSpaceCount = nil
            configuration.calibration.reliability = .uncertain
            return nil
        }

        let actualCount = snapshot.regularSpaces.count
        detectedSystemSpaceCount = actualCount
        spaceDetectionAvailable = true
        needsInitialSetup = false
        UserDefaults.standard.set(true, forKey: Self.setupCompletionKey)

        let supportedCount = min(max(actualCount, 1), 9)
        var changed = false
        if configuration.workspaces.count != supportedCount {
            resizeWorkspaces(to: supportedCount)
            changed = true
        }

        guard let order = snapshot.currentRegularOrder,
              let workspace = configuration.workspaces.first(where: { $0.order == order }) else {
            configuration.calibration.reliability = .uncertain
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
        if count > configuration.workspaces.count {
            for order in (configuration.workspaces.count + 1)...count {
                configuration.workspaces.append(Workspace(order: order, name: "工作区 \(order)"))
            }
        } else if count < configuration.workspaces.count {
            configuration.workspaces.removeLast(configuration.workspaces.count - count)
        }
        configuration.normalizeWorkspaceOrder()
    }

    private func persist() {
        let snapshot = configuration
        Task {
            do {
                try await repository.save(snapshot)
            } catch {
                await MainActor.run {
                    transientMessage = "配置保存失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
