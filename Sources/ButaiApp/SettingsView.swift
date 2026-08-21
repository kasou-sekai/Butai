import AppKit
import ButaiCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case workspaces = "工作区"
        case presets = "预设"
        case overlay = "浮窗"
        case about = "关于"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Section? = .workspaces

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: symbol(for: section))
                    .tag(section)
                    .padding(.vertical, 3)
                    .accessibilityHint("打开\(section.rawValue)设置")
            }
            .listStyle(.sidebar)
            .navigationTitle("Butai")
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.transientMessage {
                    SettingsMessageBanner(message: message) {
                        model.transientMessage = nil
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                }

                switch selection ?? .workspaces {
                case .workspaces:
                    WorkspaceSettingsView()
                case .presets:
                    PresetSettingsView()
                case .overlay:
                    OverlaySettingsView()
                case .about:
                    AboutView()
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.18), value: model.transientMessage)
        }
        .frame(minWidth: 880, minHeight: 590)
    }

    private func symbol(for section: Section) -> String {
        switch section {
        case .workspaces: "rectangle.3.group"
        case .presets: "macwindow.on.rectangle"
        case .overlay: "menubar.rectangle"
        case .about: "info.circle"
        }
    }
}

private extension View {
    @ViewBuilder
    func butaiGlassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: Color
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    @ViewBuilder
    func butaiGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct SettingsMessageBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .butaiGlassSurface(
            in: Rectangle(),
            tint: .orange.opacity(0.08),
            fallback: .orange.opacity(0.1)
        )
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct SettingsCallout: View {
    let title: String
    let detail: String
    let symbol: String
    var color: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .butaiGlassSurface(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            tint: color.opacity(0.13),
            fallback: color.opacity(0.08)
        )
    }
}

private struct StatusPill: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .butaiGlassSurface(
                in: Capsule(),
                tint: color.opacity(0.12),
                fallback: color.opacity(0.11)
            )
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
            Section("目标工作区") {
                Picker("工作区", selection: Binding(
                    get: { workspaceID },
                    set: { selectedWorkspaceID = $0 }
                )) {
                    ForEach(model.workspaces) { workspace in
                        Text("\(workspace.order). \(workspace.name)").tag(Optional(workspace.id))
                    }
                }
                .pickerStyle(.menu)

                if !isCurrentWorkspace {
                    SettingsCallout(
                        title: "请先切换到这个工作区",
                        detail: "捕获、补全和恢复布局只会作用于当前系统桌面，以保护其他桌面上的窗口。",
                        symbol: "arrow.left.arrow.right",
                        color: .orange
                    )
                }
            }

            Section("预设概览") {
                if let preset {
                    LabeledContent("名称", value: preset.name)
                    LabeledContent("项目数", value: "\(preset.items.count)")
                    LabeledContent("窗口布局") {
                        Text("\(preset.items.filter { $0.windowLayout != nil }.count) 项已记录")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsCallout(
                        title: "尚未创建预设",
                        detail: "可从当前窗口直接创建，或先建立一个空白预设再逐项添加。",
                        symbol: "rectangle.badge.plus"
                    )
                    HStack {
                        Button("新建空白预设", systemImage: "plus") {
                            guard let workspaceID else { return }
                            model.createPreset(workspaceID: workspaceID)
                        }
                        .butaiGlassButton()
                        .disabled(workspaceID == nil)
                        Spacer()
                    }
                }

                HStack(spacing: 8) {
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
                    .butaiGlassButton(prominent: true)
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
                .butaiGlassButton()

                if model.isPresetRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在处理窗口…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
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
                                    .font(.body.weight(.medium))
                                    .frame(width: 30, height: 30)
                                    .foregroundStyle(Color.accentColor)
                                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
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
                                    StatusPill(title: "布局", symbol: "rectangle.dashed", color: .secondary)
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
                    Text("从应用或文件开始，也可以为浏览器和开发工具添加专用窗口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .butaiGlassButton()

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
                    .butaiGlassButton()

                    Button("添加 ChatGPT", systemImage: "bubble.left.and.bubble.right") {
                        model.addChatGPTWindow(workspaceID: workspaceID)
                    }
                    .butaiGlassButton()
                }
            }

            if let report = model.lastPresetReport {
                Section("最近执行结果") {
                    SettingsCallout(
                        title: report.summary,
                        detail: "逐项结果保留到下一次执行，便于定位未能打开或恢复的内容。",
                        symbol: report.outcomes.allSatisfy(\.succeeded) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        color: report.outcomes.allSatisfy(\.succeeded) ? .green : .orange
                    )
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
                    SettingsCallout(
                        title: model.mappingIsReliable ? "已准备好完成设置" : "先确认当前桌面",
                        detail: model.mappingIsReliable
                            ? "Butai 已建立工作区与系统桌面的对应关系。"
                            : "确认当前位置后，Butai 才能安全地切换到正确的桌面。",
                        symbol: model.mappingIsReliable ? "checkmark.circle.fill" : "location.circle",
                        color: model.mappingIsReliable ? .green : .orange
                    )
                    HStack {
                        Spacer()
                        Button("完成初始设置") { model.completeInitialSetup() }
                            .butaiGlassButton(prominent: true)
                            .disabled(!model.mappingIsReliable)
                    }
                } header: {
                    Text("首次设置")
                }
            }

            Section("系统桌面") {
                if model.spaceDetectionAvailable {
                    LabeledContent("普通桌面数量", value: "\(model.detectedSystemSpaceCount ?? model.workspaces.count) 个（自动检测）")
                    LabeledContent("当前所在桌面") {
                        if let current = model.currentWorkspace {
                            StatusPill(
                                title: "桌面 \(current.order) · \(current.name)",
                                symbol: "location.fill",
                                color: .green
                            )
                        } else {
                            StatusPill(
                                title: "全屏或不支持的 Space",
                                symbol: "exclamationmark.triangle.fill",
                                color: .orange
                            )
                        }
                    }
                } else {
                    SettingsCallout(
                        title: "无法自动读取系统桌面",
                        detail: "你仍可手动设置桌面数量和当前位置。",
                        symbol: "exclamationmark.triangle.fill",
                        color: .orange
                    )
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
                ForEach(model.workspaces) { workspace in
                    HStack(spacing: 12) {
                        Text("\(workspace.order)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .butaiGlassSurface(
                                in: RoundedRectangle(cornerRadius: 7),
                                fallback: Color(nsColor: .quaternaryLabelColor).opacity(0.12)
                            )
                            .accessibilityLabel("桌面 \(workspace.order)")
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("工作区名称", text: Binding(
                                get: { model.workspaces.first(where: { $0.id == workspace.id })?.name ?? workspace.name },
                                set: { model.renameWorkspace(id: workspace.id, name: $0) }
                            ))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                            .font(.body.weight(.medium))
                            Text("应用：\(applicationSummary(for: workspace))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if model.currentWorkspace?.id == workspace.id {
                            StatusPill(title: "当前", symbol: "checkmark", color: .green)
                        } else {
                            Button("切换") {
                                Task { await model.navigate(to: workspace) }
                            }
                            .butaiGlassButton()
                            .controlSize(.small)
                            .disabled(model.pendingTargetOrder != nil)
                            .accessibilityLabel("切换到 \(workspace.name)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !model.spaceDetectionAvailable {
                    HStack {
                        Button("添加工作区", systemImage: "plus") { model.addWorkspace() }
                            .butaiGlassButton()
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

    private func applicationSummary(for workspace: Workspace) -> String {
        guard let names = model.applicationNames(for: workspace) else { return "无法读取" }
        return names.isEmpty ? "暂无" : names.joined(separator: "、")
    }
}

private struct OverlaySettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("显示") {
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
            }

            Section("位置") {
                overlayNumberField(
                    "顶部偏移",
                    value: Binding(
                        get: { model.configuration.settings.overlayVerticalOffset },
                        set: model.setOverlayVerticalOffset
                    )
                )
                HStack {
                    Spacer()
                    Button("恢复默认位置", systemImage: "arrow.counterclockwise") {
                        model.resetOverlayPosition()
                    }
                    .butaiGlassButton()
                }
            }

            Section("尺寸") {
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("浮窗")
    }

    private func overlayNumberField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
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
                    .labelsHidden()
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

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 54, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 112)
                .butaiGlassSurface(
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous),
                    tint: Color.accentColor.opacity(0.12),
                    interactive: true,
                    fallback: Color(nsColor: .controlBackgroundColor)
                )
                .shadow(color: .black.opacity(0.1), radius: 18, y: 8)
            Text("Butai")
                .font(.largeTitle.bold())
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [Color.accentColor.opacity(0.09), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 330
            )
        )
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.0"
    }
}
