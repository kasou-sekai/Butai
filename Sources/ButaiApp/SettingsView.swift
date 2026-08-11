import AppKit
import ButaiCore
import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case workspaces = "工作区"
        case overlay = "浮窗"
        case permissions = "权限与诊断"
        case about = "关于"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var selection: Section? = .workspaces

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.transientMessage {
                HStack {
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("关闭") { model.transientMessage = nil }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.orange.opacity(0.12))
            }

            NavigationSplitView {
                List {
                    ForEach(Section.allCases) { section in
                        Button {
                            selection = section
                        } label: {
                            HStack {
                                Label(section.rawValue, systemImage: icon(for: section))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                    }
                }
                .navigationSplitViewColumnWidth(180)
            } detail: {
                switch selection ?? .workspaces {
                case .workspaces: WorkspaceSettingsView()
                case .overlay: OverlaySettingsView()
                case .permissions: PermissionsView()
                case .about: AboutView()
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private func icon(for section: Section) -> String {
        switch section {
        case .workspaces: "rectangle.3.group"
        case .overlay: "menubar.rectangle"
        case .permissions: "checkmark.shield"
        case .about: "info.circle"
        }
    }
}

private struct WorkspaceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if model.needsInitialSetup {
                Section {
                    Label("先让 Butai 与你的普通桌面数量保持一致，然后标记当前所在桌面。", systemImage: "1.circle.fill")
                        .font(.headline)
                    Text("macOS 的公开 API 不提供普通桌面总数，因此 Butai 不能可靠地自动读取；这里只需确认一次，之后仍可随时修改。")
                        .foregroundStyle(.secondary)
                    Button("完成初始设置") { model.completeInitialSetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.mappingIsReliable)
                } header: {
                    Text("首次设置")
                }
            }

            Section("系统桌面") {
                if model.spaceDetectionAvailable {
                    LabeledContent("普通桌面数量", value: "\(model.detectedSystemSpaceCount ?? model.workspaces.count) 个（自动检测）")
                    LabeledContent(
                        "当前所在桌面",
                        value: model.currentWorkspace.map { "桌面 \($0.order) · \($0.name)" } ?? "全屏或不支持的 Space"
                    )
                    Label("工作区数量和顺序跟随 Mission Control。", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("普通桌面数量", selection: Binding(
                        get: { model.workspaces.count },
                        set: model.setWorkspaceCount
                    )) {
                        ForEach(1...9, id: \.self) { count in
                            Text("\(count) 个").tag(count)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("当前所在桌面", selection: Binding(
                        get: { model.configuration.calibration.currentWorkspaceID },
                        set: { if let id = $0 { model.calibrateCurrent(as: id) } }
                    )) {
                        Text("尚未确认").tag(UUID?.none)
                        ForEach(model.workspaces) { workspace in
                            Text("桌面 \(workspace.order) · \(workspace.name)").tag(Optional(workspace.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("工作区名称与顺序") {
                List {
                    ForEach(model.workspaces) { workspace in
                        HStack {
                            Text("\(workspace.order)")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField("工作区名称", text: Binding(
                                get: { model.workspaces.first(where: { $0.id == workspace.id })?.name ?? workspace.name },
                                set: { model.renameWorkspace(id: workspace.id, name: $0) }
                            ))
                            Text("桌面 \(workspace.order)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.currentWorkspace?.id == workspace.id {
                                Text("当前")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .frame(width: 44)
                            } else {
                                Button("切换") {
                                    Task { await model.navigate(to: workspace) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.pendingTargetOrder != nil)
                                .frame(width: 44)
                                .accessibilityLabel("切换到 \(workspace.name)")
                            }
                        }
                    }
                }
                .frame(minHeight: 220)

                if !model.spaceDetectionAvailable {
                    HStack {
                        Button("添加工作区", systemImage: "plus") { model.addWorkspace() }
                            .disabled(model.workspaces.count >= 9)
                        Spacer()
                        Text("最多 9 个").foregroundStyle(.secondary)
                    }
                }
            }

            Section("关于桌面映射") {
                Text("Butai 在运行期间读取 WindowServer 的 Space 拓扑，私有 Space ID 不会写入配置文件。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("工作区")
    }
}

private struct OverlaySettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Toggle("显示顶部工作区浮窗", isOn: Binding(
                get: { model.configuration.settings.overlayVisible },
                set: model.setOverlayVisible
            ))
            Text("浮窗会加入所有普通 Spaces，默认不抢键盘焦点。可以直接拖动浮窗微调位置。")
                .foregroundStyle(.secondary)
            LabeledContent("水平偏移", value: "\(Int(model.configuration.settings.overlayHorizontalOffset)) pt")
            LabeledContent("垂直偏移", value: "\(Int(model.configuration.settings.overlayVerticalOffset)) pt")
            Button("恢复默认位置") { model.resetOverlayPosition() }
        }
        .formStyle(.grouped)
        .navigationTitle("浮窗")
    }
}

private struct PermissionsView: View {
    @State private var checks = CompatibilityChecker.checks()

    var body: some View {
        Form {
            Section("系统兼容性检查") {
                ForEach(checks) { check in
                    HStack(alignment: .top) {
                        Image(systemName: symbol(for: check.state))
                            .foregroundStyle(color(for: check.state))
                            .frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(check.title).fontWeight(.medium)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = check.repairURL {
                            Button("修复") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            HStack {
                Button("请求辅助功能权限") { CompatibilityChecker.requestAccessibility() }
                Button("请求输入监听权限") { CompatibilityChecker.requestInputMonitoring() }
                Spacer()
                Button("重新检查") { checks = CompatibilityChecker.checks() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("权限与诊断")
    }

    private func symbol(for state: CompatibilityCheck.State) -> String {
        switch state { case .pass: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failure: "xmark.circle.fill" }
    }

    private func color(for state: CompatibilityCheck.State) -> Color {
        switch state { case .pass: .green; case .warning: .yellow; case .failure: .red }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "theatermasks.fill").font(.system(size: 64))
            Text("Butai").font(.largeTitle.bold())
            Text("Set the stage for your work.")
            Text("首版技术预览 · 配置仅保存在本机")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
