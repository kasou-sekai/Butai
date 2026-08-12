import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private static let popupHeight: CGFloat = 44
    private static let popupSpacing: CGFloat = 4
    private static let animationDuration = 0.18

    private let model: AppModel
    private let panel: NSPanel
    private let popupPanel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var expanded = false
    private var anchorHovered = false
    private var popupHovered = false
    private var isPositioningProgrammatically = false

    init(model: AppModel) {
        self.model = model
        self.panel = Self.makePanel()
        self.popupPanel = Self.makePanel()
        super.init()

        configure(panel)
        configure(popupPanel)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: OverlayAnchorView(
                onHoverChanged: { [weak self] hovering in
                    self?.anchorHoverChanged(hovering)
                },
                onToggle: { [weak self] in
                    self?.setExpanded(!(self?.expanded ?? false))
                }
            )
            .environmentObject(model)
        )
        popupPanel.contentView = NSHostingView(
            rootView: OverlayPopupView(
                onHoverChanged: { [weak self] hovering in
                    self?.popupHoverChanged(hovering)
                },
                onWorkspaceSelected: { [weak self] in
                    self?.setExpanded(false)
                }
            )
            .environmentObject(model)
        )

        model.$configuration
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        model.$isCurrentSpaceFullscreen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func show() {
        refresh()
    }

    func reposition() {
        positionPanel()
        if expanded { positionPopupPanel() }
    }

    private static func makePanel() -> NSPanel {
        NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func configure(_ target: NSPanel) {
        target.level = .statusBar
        target.isOpaque = false
        target.backgroundColor = .clear
        target.hasShadow = false
        target.hidesOnDeactivate = false
        target.isMovableByWindowBackground = false
        target.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    private func anchorHoverChanged(_ hovering: Bool) {
        anchorHovered = hovering
        if hovering {
            collapseTask?.cancel()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    private func popupHoverChanged(_ hovering: Bool) {
        popupHovered = hovering
        if hovering {
            collapseTask?.cancel()
        } else {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, let self,
                  !self.anchorHovered, !self.popupHovered else { return }
            self.setExpanded(false)
        }
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        guard !value || (model.configuration.settings.overlayVisible && !model.isCurrentSpaceFullscreen) else {
            return
        }
        guard !value || model.workspaces.contains(where: { $0.id != model.currentWorkspace?.id }) else {
            return
        }
        expanded = value
        collapseTask?.cancel()
        if value {
            showPopupPanel()
        } else {
            hidePopupPanel()
        }
    }

    private func showPopupPanel() {
        guard let finalFrame = popupFrame() else { return }
        var startFrame = finalFrame
        startFrame.origin.y += 6
        popupPanel.setFrame(startFrame, display: true)
        popupPanel.alphaValue = 0
        popupPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            popupPanel.animator().setFrame(finalFrame, display: true)
            popupPanel.animator().alphaValue = 1
        }
    }

    private func hidePopupPanel(immediately: Bool = false) {
        collapseTask?.cancel()
        guard popupPanel.isVisible else { return }
        if immediately {
            popupPanel.orderOut(nil)
            popupPanel.alphaValue = 1
            return
        }

        var targetFrame = popupPanel.frame
        targetFrame.origin.y += 4
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration * 0.8
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            popupPanel.animator().setFrame(targetFrame, display: true)
            popupPanel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.animationDuration))
            guard let self, !self.expanded else { return }
            self.popupPanel.orderOut(nil)
            self.popupPanel.alphaValue = 1
        }
    }

    private func refresh() {
        if model.configuration.settings.overlayVisible && !model.isCurrentSpaceFullscreen {
            positionPanel()
            panel.orderFrontRegardless()
            if expanded { positionPopupPanel() }
        } else {
            expanded = false
            anchorHovered = false
            popupHovered = false
            panel.orderOut(nil)
            hidePopupPanel(immediately: true)
        }
    }

    private func preferredCollapsedSize() -> NSSize {
        let name = model.displayWorkspace?.name ?? "未校准"
        var width = textWidth(name, font: .systemFont(ofSize: 13, weight: .semibold))
        if let order = model.displayWorkspace?.order {
            width += textWidth(" · \(order)", font: .systemFont(ofSize: 13)) + 4
        }
        if !model.mappingIsReliable { width += 18 }
        let screen = NSScreen.main ?? NSScreen.screens.first
        return NSSize(width: ceil(width + 16), height: statusBarHeight(for: screen))
    }

    private func preferredPopupSize() -> NSSize {
        let otherWorkspaces = model.workspaces.filter { $0.id != model.currentWorkspace?.id }
        let itemWidths = otherWorkspaces.map { workspace in
            textWidth(
                "\(workspace.name) · \(workspace.order)",
                font: .systemFont(ofSize: 13, weight: .medium)
            ) + 24
        }
        let width = max(
            52,
            itemWidths.reduce(0, +) + CGFloat(max(0, itemWidths.count - 1)) * 6 + 8
        )
        let maximumWidth = (NSScreen.main ?? NSScreen.screens.first)?.frame.width ?? width
        return NSSize(width: min(ceil(width), maximumWidth), height: Self.popupHeight)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func statusBarHeight(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return NSStatusBar.system.thickness }
        let reservedTopHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return max(reservedTopHeight, NSStatusBar.system.thickness)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = preferredCollapsedSize()
        let screenFrame = screen.frame
        let desiredX = screenFrame.midX - size.width / 2
            + model.configuration.settings.overlayHorizontalOffset
        let origin = NSPoint(
            x: min(max(desiredX, screenFrame.minX), screenFrame.maxX - size.width),
            y: screenFrame.maxY - size.height
        )
        isPositioningProgrammatically = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        isPositioningProgrammatically = false
    }

    private func popupFrame() -> NSRect? {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let size = preferredPopupSize()
        let desiredX = panel.frame.midX - size.width / 2
        let origin = NSPoint(
            x: min(max(desiredX, screen.frame.minX), screen.frame.maxX - size.width),
            y: panel.frame.minY - Self.popupSpacing - size.height
        )
        return NSRect(origin: origin, size: size)
    }

    private func positionPopupPanel() {
        guard let frame = popupFrame() else { return }
        popupPanel.setFrame(frame, display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioningProgrammatically,
              let screen = panel.screen ?? NSScreen.main else { return }
        let horizontal = panel.frame.midX - screen.frame.midX
        model.setOverlayOffsets(horizontal: horizontal, vertical: 0)
        if expanded { positionPopupPanel() }
    }
}

private struct OverlayAnchorView: View {
    @EnvironmentObject private var model: AppModel
    let onHoverChanged: (Bool) -> Void
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                if !model.mappingIsReliable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Text(model.displayWorkspace?.name ?? "未校准")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let order = model.displayWorkspace?.order {
                    Text("· \(order)").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.14))
        )
        .onHover(perform: onHoverChanged)
        .accessibilityLabel("Butai 当前工作区")
    }
}

private struct OverlayPopupView: View {
    @EnvironmentObject private var model: AppModel
    let onHoverChanged: (Bool) -> Void
    let onWorkspaceSelected: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.workspaces.filter { $0.id != model.currentWorkspace?.id }) { workspace in
                Button {
                    onWorkspaceSelected()
                    Task { await model.navigate(to: workspace) }
                } label: {
                    Text("\(workspace.name) · \(workspace.order)")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到 \(workspace.name)")
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.14))
        )
        .onHover(perform: onHoverChanged)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("其他桌面")
    }
}
