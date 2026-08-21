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
    private let membershipRepairer = SystemSpaceWindowMembershipRepairer()
    private let panel: NSPanel
    private let popupPanel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var spaceRepairTask: Task<Void, Never>?
    private var revealHideTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var expanded = false
    private var anchorHovered = false
    private var popupHovered = false
    private var fullscreenRevealed = false
    private var isPositioningProgrammatically = false

    private static var allSpacesBehavior: NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]
        if #available(macOS 26.0, *) {
            // Apple recommends this behavior for floating windows and system
            // overlays that need to join other applications' full-screen Spaces.
            behavior.insert(.canJoinAllApplications)
        } else {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }

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

        model.$pendingTargetOrder
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        installMouseMonitors()
    }

    func show() {
        refresh()
    }

    func reposition() {
        positionPanel()
        if expanded { positionPopupPanel() }
    }

    func activeSpaceDidChange() {
        // The notification arrives while WindowServer may still be animating
        // and rebuilding Space membership. Toggling canJoinAllSpaces during
        // that interval can pin a panel to the transition's current Space.
        spaceRepairTask?.cancel()
        spaceRepairTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self else { return }
            self.repairPanelMembershipWithoutReordering()
            self.refresh()

            // Give longer full-screen transitions a second chance without
            // detaching a healthy panel again.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, self.overlayShouldBeVisible else { return }
            if !self.panel.isOnActiveSpace {
                self.repairPanelMembershipWithoutReordering()
                self.refresh()
            } else {
                self.panel.orderFrontRegardless()
                if self.expanded { self.popupPanel.orderFrontRegardless() }
            }
        }
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
        target.collectionBehavior = Self.allSpacesBehavior
    }

    private func anchorHoverChanged(_ hovering: Bool) {
        anchorHovered = hovering
        if hovering {
            cancelRevealHide()
            collapseTask?.cancel()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    private func popupHoverChanged(_ hovering: Bool) {
        popupHovered = hovering
        if hovering {
            cancelRevealHide()
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
        guard !value || overlayShouldBeVisible else {
            return
        }
        guard !value || model.overlaySpaces.count > 1 else {
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
        if !model.isCurrentSpaceFullscreen {
            fullscreenRevealed = false
            cancelRevealHide()
        }
        if overlayShouldBeVisible {
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

    private var overlayShouldBeVisible: Bool {
        guard model.configuration.settings.overlayVisible,
              model.pendingTargetOrder == nil else { return false }
        guard model.isCurrentSpaceFullscreen else { return true }
        switch model.configuration.settings.fullscreenOverlayMode ?? .always {
        case .hidden:
            return false
        case .revealAtTop:
            return fullscreenRevealed
        case .always:
            return true
        }
    }

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in
                self?.mouseLocationDidChange(NSEvent.mouseLocation)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.mouseLocationDidChange(NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func mouseLocationDidChange(_ location: NSPoint) {
        guard model.isCurrentSpaceFullscreen,
              model.configuration.settings.overlayVisible,
              (model.configuration.settings.fullscreenOverlayMode ?? .always) == .revealAtTop else {
            return
        }

        if fullscreenHotRegion.contains(location) {
            cancelRevealHide()
            if !fullscreenRevealed {
                fullscreenRevealed = true
                refresh()
            }
            return
        }

        let overVisibleOverlay = panel.isVisible && panel.frame.insetBy(dx: -12, dy: -12).contains(location)
            || popupPanel.isVisible && popupPanel.frame.insetBy(dx: -12, dy: -12).contains(location)
        guard !overVisibleOverlay, !anchorHovered, !popupHovered else {
            cancelRevealHide()
            return
        }
        scheduleFullscreenRevealHide()
    }

    private var fullscreenHotRegion: NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let size = preferredCollapsedSize()
        let desiredX = screen.frame.midX - size.width / 2
        let clampedX = min(max(desiredX, screen.frame.minX), screen.frame.maxX - size.width)
        return NSRect(
            x: clampedX - 32,
            y: screen.frame.maxY - 14,
            width: size.width + 64,
            height: 14
        )
    }

    private func scheduleFullscreenRevealHide() {
        guard fullscreenRevealed, revealHideTask == nil else { return }
        revealHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self,
                  !self.anchorHovered, !self.popupHovered else { return }
            self.fullscreenRevealed = false
            self.revealHideTask = nil
            self.refresh()
        }
    }

    private func cancelRevealHide() {
        revealHideTask?.cancel()
        revealHideTask = nil
    }

    private func repairPanelMembershipWithoutReordering() {
        // Update WindowServer membership in place. Unlike orderOut/toggle/orderFront,
        // this preserves visibility, alpha, frame and the popup's hover state.
        panel.collectionBehavior = Self.allSpacesBehavior
        popupPanel.collectionBehavior = Self.allSpacesBehavior
        _ = membershipRepairer.add(
            windowNumbers: [panel.windowNumber, popupPanel.windowNumber],
            to: model.systemSpaceIDs
        )
    }

    private func preferredCollapsedSize() -> NSSize {
        let currentItem = model.overlaySpaces.first(where: \.isCurrent)
        let name = currentItem?.workspace?.name
            ?? currentItem?.applicationName
            ?? "未校准"
        var width = textWidth(name, font: .systemFont(ofSize: 13, weight: .semibold))
        if !model.mappingIsReliable { width += 18 }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let automaticWidth = ceil(width + 16)
        let configuredWidth = CGFloat(
            model.configuration.settings.overlayWidth ?? Double(automaticWidth)
        )
        let configuredHeight = CGFloat(
            model.configuration.settings.overlayHeight
                ?? Double(statusBarHeight(for: screen))
        )
        let maximumWidth = screen?.frame.width ?? configuredWidth
        let maximumHeight = screen?.frame.height ?? configuredHeight
        return NSSize(
            width: min(max(configuredWidth, 52), maximumWidth),
            height: min(max(configuredHeight, 16), maximumHeight)
        )
    }

    private func preferredPopupSize() -> NSSize {
        let itemWidths = model.overlaySpaces.map { item in
            let contentWidth = item.workspace.map {
                textWidth($0.name, font: .systemFont(ofSize: 13, weight: .medium))
            } ?? textWidth(
                item.applicationName ?? "全屏应用",
                font: .systemFont(ofSize: 13, weight: .medium)
            )
            return contentWidth + 24 + (item.isCurrent ? 18 : 0)
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
        let origin = NSPoint(
            x: min(max(desiredX, screenFrame.minX), screenFrame.maxX - size.width),
            y: min(
                max(
                    screenFrame.maxY - size.height
                        - model.configuration.settings.overlayVerticalOffset,
                    screenFrame.minY
                ),
                screenFrame.maxY - size.height
            )
        )
        isPositioningProgrammatically = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        isPositioningProgrammatically = false
    }

    private func popupFrame() -> NSRect? {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let size = preferredPopupSize()
        let desiredX = panel.frame.midX - size.width / 2
        let desiredY = panel.frame.minY - Self.popupSpacing - size.height
        let origin = NSPoint(
            x: min(max(desiredX, screen.frame.minX), screen.frame.maxX - size.width),
            y: min(max(desiredY, screen.frame.minY), screen.frame.maxY - size.height)
        )
        return NSRect(origin: origin, size: size)
    }

    private func positionPopupPanel() {
        guard let frame = popupFrame() else { return }
        popupPanel.setFrame(frame, display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioningProgrammatically else { return }
        // Horizontal movement is not user-configurable. If WindowServer or a
        // drag changes the panel frame, immediately restore the centered
        // position instead of persisting a new offset.
        positionPanel()
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
                if let current = model.overlaySpaces.first(where: \.isCurrent), current.isFullscreen {
                    Text(current.applicationName ?? "全屏应用")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Text(model.currentWorkspace?.name ?? "未校准")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.overlaySpaces) { item in
                    Button {
                        guard !item.isCurrent else { return }
                        onWorkspaceSelected()
                        Task { await model.navigate(to: item) }
                    } label: {
                        HStack(spacing: 5) {
                            if item.isCurrent {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            if let workspace = item.workspace {
                                Text(workspace.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                Text(item.applicationName ?? "全屏应用")
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(
                                item.isCurrent ? Color.accentColor.opacity(0.2) : .white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: item))
                }
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
        .accessibilityLabel("桌面与全屏应用")
    }

    private func accessibilityLabel(for item: OverlaySpaceItem) -> String {
        let name = item.workspace?.name ?? item.applicationName ?? "全屏应用"
        return item.isCurrent ? "当前位置，\(name)" : "切换到 \(name)"
    }
}
