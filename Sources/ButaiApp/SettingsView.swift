import AppKit
import ButaiCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case workspaces = "工作区"
        case presets = "预设"
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

            TabView(selection: Binding(
                get: { selection ?? .workspaces },
                set: { selection = $0 }
            )) {
                WorkspaceSettingsView()
                    .tabItem { Label("工作区", systemImage: "rectangle.3.group") }
                    .tag(Section.workspaces)
                PresetSettingsView()
                    .tabItem { Label("预设", systemImage: "macwindow.on.rectangle") }
                    .tag(Section.presets)
                OverlaySettingsView()
                    .tabItem { Label("浮窗", systemImage: "menubar.rectangle") }
                    .tag(Section.overlay)
                PermissionsView()
                    .tabItem { Label("权限", systemImage: "checkmark.shield") }
                    .tag(Section.permissions)
                AboutView()
                    .tabItem { Label("关于", systemImage: "info.circle") }
                    .tag(Section.about)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 500)
        .background(SettingsWindowConfigurator())
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else {
            DispatchQueue.main.async {
                configure(nsView.window)
            }
            return
        }
        configure(window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        if !NSApplication.shared.isActive {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }
}

private struct PresetSettingsView: View {
    private enum ImportKind { case application, file, folder, vscodeFolder, vscodeWorkspace }

    @EnvironmentObject private var model: AppModel
    @State private var selectedWorkspaceID: UUID?
    @State private var importKind: ImportKind?
    @State private var urlText = ""
    @State private var edgeURLsText = ""
    @State private var edgeProfile = ""
    @State private var confirmCapture = false
    @State private var confirmDelete = false

    private var workspaceID: UUID? {
        selectedWorkspaceID ?? model.currentWorkspace?.id ?? model.workspaces.first?.id
    }

    private var workspace: Workspace? {
        guard let workspaceID else { return nil }
        return model.workspaces.first { $0.id == workspaceID }
    }

    private var preset: Preset? {
        guard let workspaceID else { return nil }
        return model.preset(for: workspaceID)
    }

    private var isCurrentWorkspace: Bool {
        workspaceID == model.currentWorkspace?.id
    }

    var body: some View {
        Form {
            Section("工作区") {
                Picker("工作区", selection: Binding(
                    get: { workspaceID },
                    set: { selectedWorkspaceID = $0 }
                )) {
                    ForEach(model.workspaces) { workspace in
                        Text("\(workspace.order). \(workspace.name)").tag(Optional(workspace.id))
                    }
                }
                .pickerStyle(.menu)
            }

            Section("预设") {
                if let preset {
                    LabeledContent("名称", value: preset.name)
                    LabeledContent("项目数", value: "\(preset.items.count)")
                } else {
                    ContentUnavailableView("尚未创建预设", systemImage: "rectangle.badge.plus")
                    Button("新建空白预设", systemImage: "plus") {
                        guard let workspaceID else { return }
                        model.createPreset(workspaceID: workspaceID)
                    }
                    .disabled(workspaceID == nil)
                }

                HStack {
                    Button(
                        preset == nil ? "从当前窗口创建" : "用当前窗口替换",
                        systemImage: "camera.viewfinder"
                    ) {
                        confirmCapture = true
                    }
                    .disabled(!isCurrentWorkspace || model.isPresetRunning)

                    Button("补全", systemImage: "plus.rectangle.on.rectangle") {
                        Task { await model.completeCurrentPreset() }
                    }
                    .disabled(!isCurrentWorkspace || preset == nil || model.isPresetRunning)

                    Button("恢复布局", systemImage: "rectangle.3.group") {
                        Task { await model.restoreCurrentLayout() }
                    }
                    .disabled(!isCurrentWorkspace || preset == nil || model.isPresetRunning)

                    Spacer()

                    Button("删除预设", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                    .disabled(preset == nil)
                }

                if model.isPresetRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let preset, let workspaceID {
                Section("预设项目") {
                    if preset.items.isEmpty {
                        ContentUnavailableView("预设为空", systemImage: "tray")
                    } else {
                        ForEach(preset.items.sorted(by: { $0.sortOrder < $1.sortOrder })) { item in
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: item.kind))
                                    .frame(width: 22)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .lineLimit(1)
                                    Text(detail(for: item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if item.windowLayout != nil {
                                    Image(systemName: "rectangle.dashed")
                                        .foregroundStyle(.secondary)
                                        .help("已保存窗口布局")
                                }
                                Button(role: .destructive) {
                                    model.deletePresetItem(
                                        workspaceID: workspaceID,
                                        itemID: item.id
                                    )
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("删除 \(item.displayName)")
                            }
                        }
                        .onDelete { model.deletePresetItems(workspaceID: workspaceID, at: $0) }
                    }
                }

                Section("添加项目") {
                    HStack {
                        Menu("添加项目", systemImage: "plus") {
                            Button("应用…") { importKind = .application }
                            Button("文件…") { importKind = .file }
                            Button("Finder 文件夹…") { importKind = .folder }
                            Divider()
                            Button("VS Code 文件夹…") { importKind = .vscodeFolder }
                            Button("VS Code 工作区…") { importKind = .vscodeWorkspace }
                        }

                        TextField("URL", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                        Button("添加 URL") {
                            model.addPresetURL(workspaceID: workspaceID, value: urlText)
                            urlText = ""
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack {
                        TextField("Edge URL（可多个）", text: $edgeURLsText)
                            .textFieldStyle(.roundedBorder)
                        TextField("Profile", text: $edgeProfile)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 150)
                        Button("添加 Edge") {
                            model.addEdgeWindow(
                                workspaceID: workspaceID,
                                urlsText: edgeURLsText,
                                profile: edgeProfile
                            )
                            edgeURLsText = ""
                            edgeProfile = ""
                        }
                        .disabled(edgeURLsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button("添加 ChatGPT", systemImage: "bubble.left.and.bubble.right") {
                        model.addChatGPTWindow(workspaceID: workspaceID)
                    }
                }
            } else {
                Section("添加项目") {
                    Button("新建空白预设", systemImage: "plus") {
                        guard let workspaceID else { return }
                        model.createPreset(workspaceID: workspaceID)
                    }
                    .disabled(workspaceID == nil)
                }
            }

            if let report = model.lastPresetReport {
                Section("最近执行结果") {
                    LabeledContent("摘要", value: report.summary)
                    ForEach(report.outcomes) { result in
                        HStack {
                            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.succeeded ? .green : .orange)
                            VStack(alignment: .leading) {
                                Text(result.displayName)
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("预设")
        .onAppear {
            selectedWorkspaceID = model.currentWorkspace?.id ?? model.workspaces.first?.id
        }
        .confirmationDialog(
            preset == nil
                ? "从当前窗口创建 \(workspace?.name ?? "当前工作区") 的预设？"
                : "替换 \(workspace?.name ?? "当前工作区") 的预设？",
            isPresented: $confirmCapture,
            titleVisibility: .visible
        ) {
            Button(preset == nil ? "创建" : "替换") {
                Task { await model.captureCurrentWindowsAsPreset() }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除 \(workspace?.name ?? "当前工作区") 的预设？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let workspaceID else { return }
                model.deletePreset(workspaceID: workspaceID)
            }
            Button("取消", role: .cancel) {}
        }
        .fileImporter(
            isPresented: Binding(
                get: { importKind != nil },
                set: { if !$0 { importKind = nil } }
            ),
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard let workspaceID, let kind = importKind else { return }
            defer { importKind = nil }
            guard case let .success(urls) = result, let url = urls.first else { return }
            model.addPresetResource(workspaceID: workspaceID, kind: presetKind(for: kind), url: url)
        }
    }

    private var allowedContentTypes: [UTType] {
        switch importKind {
        case .application: [.application]
        case .folder, .vscodeFolder: [.folder]
        case .vscodeWorkspace: [UTType(filenameExtension: "code-workspace") ?? .json]
        case .file, .none: [.item]
        }
    }

    private func presetKind(for kind: ImportKind) -> PresetItem.Kind {
        switch kind {
        case .application: .application
        case .file: .file
        case .folder: .finderFolder
        case .vscodeFolder: .vscodeFolder
        case .vscodeWorkspace: .vscodeWorkspace
        }
    }

    private func icon(for kind: PresetItem.Kind) -> String {
        switch kind {
        case .application: "app"
        case .file: "doc"
        case .folder, .finderFolder: "folder"
        case .url, .edgeWindow: "link"
        case .vscodeFolder, .vscodeWorkspace: "chevron.left.forwardslash.chevron.right"
        case .chatGPTWindow: "bubble.left.and.bubble.right"
        case .command: "terminal"
        }
    }

    private func detail(for item: PresetItem) -> String {
        item.resourcePath ?? item.applicationBundleIdentifier ?? item.kind.rawValue
    }
}

private struct WorkspaceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            if model.needsInitialSetup {
                Section {
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
            Picker("全屏应用上的浮窗", selection: Binding(
                get: { model.configuration.settings.fullscreenOverlayMode ?? .always },
                set: model.setFullscreenOverlayMode
            )) {
                Text("彻底隐藏").tag(AppSettings.FullscreenOverlayMode.hidden)
                Text("移到顶部时显示").tag(AppSettings.FullscreenOverlayMode.revealAtTop)
                Text("始终显示").tag(AppSettings.FullscreenOverlayMode.always)
            }
            Text("“移到顶部时显示”会在指针靠近浮窗对应的屏幕顶部位置时临时显示。此设置仅影响全屏应用 Space。")
                .font(.caption)
                .foregroundStyle(.secondary)
            overlayNumberField(
                "水平偏移",
                value: Binding(
                    get: { model.configuration.settings.overlayHorizontalOffset },
                    set: model.setOverlayHorizontalOffset
                )
            )
            overlayNumberField(
                "顶部偏移",
                value: Binding(
                    get: { model.configuration.settings.overlayVerticalOffset },
                    set: model.setOverlayVerticalOffset
                )
            )
            overlaySizeField(
                "宽度",
                value: Binding(
                    get: { model.configuration.settings.overlayWidth ?? model.automaticOverlayWidth },
                    set: { model.setOverlayWidth($0) }
                ),
                automatic: Binding(
                    get: { model.configuration.settings.overlayWidth == nil },
                    set: { model.setOverlayWidth($0 ? nil : model.automaticOverlayWidth) }
                )
            )
            overlaySizeField(
                "高度",
                value: Binding(
                    get: { model.configuration.settings.overlayHeight ?? model.automaticOverlayHeight },
                    set: { model.setOverlayHeight($0) }
                ),
                automatic: Binding(
                    get: { model.configuration.settings.overlayHeight == nil },
                    set: { model.setOverlayHeight($0 ? nil : model.automaticOverlayHeight) }
                )
            )
            Button("恢复默认位置") { model.resetOverlayPosition() }
        }
        .formStyle(.grouped)
        .navigationTitle("浮窗")
    }

    private func overlayNumberField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 78)
                Text("pt")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func overlaySizeField(
        _ title: String,
        value: Binding<Double>,
        automatic: Binding<Bool>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 78)
                    .disabled(automatic.wrappedValue)
                Text("pt")
                    .foregroundStyle(.secondary)
                Toggle("自动", isOn: automatic)
                    .toggleStyle(.checkbox)
            }
        }
    }
}

private struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel
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
            Section("应用适配器") {
                ForEach(model.adapterHealth) { adapter in
                    HStack(alignment: .top) {
                        Image(systemName: adapterSymbol(adapter.state))
                            .foregroundStyle(adapterColor(adapter.state))
                            .frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(adapter.name).fontWeight(.medium)
                            Text(adapter.detail).font(.caption).foregroundStyle(.secondary)
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

    private func adapterSymbol(_ state: AdapterHealth.State) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .degraded, .experimental: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    private func adapterColor(_ state: AdapterHealth.State) -> Color {
        switch state {
        case .ready: .green
        case .degraded, .experimental: .yellow
        case .unavailable: .red
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "theatermasks.fill").font(.system(size: 64))
            Text("Butai").font(.largeTitle.bold())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
