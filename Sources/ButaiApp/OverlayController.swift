import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var expanded = false
    private var isPositioningProgrammatically = false

    init(model: AppModel) {
        self.model = model
        self.panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: OverlayView(onExpansionChanged: { [weak self] value in
                self?.setExpanded(value)
            })
            .environmentObject(model)
        )

        model.$configuration
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                self?.applyVisibility(config.settings.overlayVisible)
            }
            .store(in: &cancellables)
    }

    func show() {
        applyVisibility(model.configuration.settings.overlayVisible)
    }

    func reposition() {
        positionPanel(size: panel.frame.size)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        let size = value ? NSSize(width: 620, height: 150) : NSSize(width: 240, height: 40)
        positionPanel(size: size, animate: true)
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            let size = expanded ? NSSize(width: 620, height: 150) : NSSize(width: 240, height: 40)
            positionPanel(size: size)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func positionPanel(size: NSSize, animate: Bool = false) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let settings = model.configuration.settings
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2 + settings.overlayHorizontalOffset,
            y: visible.maxY - size.height - 8 - settings.overlayVerticalOffset
        )
        isPositioningProgrammatically = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animate)
        isPositioningProgrammatically = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioningProgrammatically,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let horizontal = panel.frame.midX - visible.midX
        let vertical = visible.maxY - panel.frame.maxY - 8
        model.setOverlayOffsets(horizontal: horizontal, vertical: vertical)
    }
}

private struct OverlayView: View {
    @EnvironmentObject private var model: AppModel
    let onExpansionChanged: (Bool) -> Void
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        Group {
            if expanded { expandedContent } else { collapsedContent }
        }
        .padding(expanded ? 12 : 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: expanded ? 18 : 14))
        .overlay(
            RoundedRectangle(cornerRadius: expanded ? 18 : 14)
                .strokeBorder(.white.opacity(0.14))
        )
        .onHover { hovering in
            collapseTask?.cancel()
            if hovering {
                expanded = true
                onExpansionChanged(true)
            } else {
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    expanded = false
                    onExpansionChanged(false)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Butai 当前工作区")
    }

    private var collapsedContent: some View {
        HStack(spacing: 7) {
            if !model.mappingIsReliable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            Text(model.displayWorkspace?.name ?? "未校准")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let order = model.displayWorkspace?.order {
                Text("· \(order)").foregroundStyle(.secondary)
            }
        }
        .frame(width: 220, height: 24)
    }

    private var expandedContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(model.workspaces) { workspace in
                    Button {
                        Task { await model.navigate(to: workspace) }
                    } label: {
                        VStack(spacing: 3) {
                            Text(workspace.name).lineLimit(1)
                            Text("\(workspace.order)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 72)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.currentWorkspace?.id == workspace.id ? .accentColor : .gray)
                    .accessibilityLabel("切换到 \(workspace.name)")
                }
            }

            Divider()

            HStack {
                if let message = model.transientMessage {
                    Label(message, systemImage: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if model.mappingIsReliable {
                    Label("映射已确认", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("需要重新校准", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Spacer()
                if model.isPresetRunning {
                    ProgressView().controlSize(.small)
                }
                Button("补全预设") {
                    Task { await model.completeCurrentPreset() }
                }
                .disabled(model.currentPreset == nil || model.isPresetRunning)
                Button("恢复布局") {
                    Task { await model.restoreCurrentLayout() }
                }
                .disabled(model.currentPreset == nil || model.isPresetRunning)
            }
            .font(.caption)
        }
        .frame(width: 596, height: 126)
    }
}
