import AppKit
import ApplicationServices
import ButaiCore
import CoreGraphics
import Foundation

@MainActor
final class WindowPresetEngine {
    struct RuntimeWindow {
        let pid: pid_t
        let bundleIdentifier: String
        let applicationName: String
        let applicationPath: String?
        let title: String
        let bounds: CGRect

        var discovered: DiscoveredWindow {
            DiscoveredWindow(bundleIdentifier: bundleIdentifier, title: title)
        }
    }

    func captureVisibleWindows() -> [PresetItem] {
        discoverVisibleWindows().enumerated().map { index, window in
            let applicationURL = window.applicationPath.map { URL(fileURLWithPath: $0) }
            let kind = capturedKind(bundleIdentifier: window.bundleIdentifier)
            return PresetItem(
                kind: kind,
                applicationBundleIdentifier: window.bundleIdentifier,
                applicationPath: applicationURL?.path,
                displayName: window.title.isEmpty ? window.applicationName : window.title,
                openPolicy: .reusePreferred,
                matchRules: window.title.isEmpty ? [] : [
                    WindowMatchRule(kind: .titleExact, value: window.title, weight: 35)
                ],
                windowLayout: normalizedLayout(for: window.bounds),
                sortOrder: index
            )
        }
    }

    func execute(preset: Preset, mode: PresetExecutionReport.Mode) async -> PresetExecutionReport {
        let startedAt = Date()
        var outcomes: [PresetItemOutcome] = []

        for item in preset.items.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard !Task.isCancelled else {
                outcomes.append(outcome(item, .skipped, "任务已取消"))
                continue
            }
            guard item.enabled else {
                outcomes.append(outcome(item, .skipped, "项目已停用"))
                continue
            }
            outcomes.append(await execute(item: item, mode: mode))
        }

        return PresetExecutionReport(
            presetID: preset.id,
            presetName: preset.name,
            mode: mode,
            outcomes: outcomes,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    func discoverVisibleWindows() -> [RuntimeWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { info in
            guard let rawBounds = info[kCGWindowBounds as String] else { return nil }
            let boundsDictionary = rawBounds as! CFDictionary
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 120, bounds.height >= 80,
                  let application = NSRunningApplication(processIdentifier: ownerPID),
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

            let title = (info[kCGWindowName as String] as? String) ?? ""
            guard !title.isEmpty || bounds.width >= 320 else { return nil }
            return RuntimeWindow(
                pid: ownerPID,
                bundleIdentifier: bundleIdentifier,
                applicationName: application.localizedName ?? bundleIdentifier,
                applicationPath: application.bundleURL?.path,
                title: title,
                bounds: bounds
            )
        }
    }

    private func execute(item: PresetItem, mode: PresetExecutionReport.Mode) async -> PresetItemOutcome {
        var windows = discoverVisibleWindows()
        if let existing = bestMatch(for: item, in: windows) {
            if mode == .restore, let layout = item.windowLayout {
                guard existing.match.confidence == .high else {
                    return outcome(item, .lowConfidence, "找到可能匹配的窗口，但置信度不足，未移动")
                }
                return restore(window: existing.window, layout: layout)
                    ? outcome(item, .restored, "窗口布局已恢复")
                    : outcome(item, .permissionDenied, "无法调整窗口；请检查辅助功能权限")
            }
            return outcome(item, .ready, "已有匹配窗口")
        }

        do {
            try open(item: item)
        } catch OpenError.applicationNotFound {
            return outcome(item, .applicationNotFound, "找不到目标应用")
        } catch OpenError.unsupported {
            return outcome(item, .unsupported, "当前版本不执行此项目类型")
        } catch {
            return outcome(item, .openFailed, error.localizedDescription)
        }

        // Files and generic URLs do not identify the application/window that will
        // handle them, so there is no safe target to poll or reposition.
        if item.applicationBundleIdentifier == nil && item.matchRules.isEmpty {
            return outcome(item, .opened, "已发送打开请求")
        }

        let deadline = Date().addingTimeInterval(min(max(item.timeoutSeconds, 1), 20))
        repeat {
            try? await Task.sleep(for: .milliseconds(250))
            windows = discoverVisibleWindows()
            if let opened = bestMatch(for: item, in: windows) {
                if mode == .restore, let layout = item.windowLayout,
                   opened.match.confidence == .high {
                    return restore(window: opened.window, layout: layout)
                        ? outcome(item, .restored, "已打开并恢复布局")
                        : outcome(item, .permissionDenied, "项目已打开，但无法调整窗口")
                }
                return outcome(item, .opened, "项目已打开")
            }
        } while Date() < deadline && !Task.isCancelled

        return outcome(item, .windowTimeout, "已发出打开请求，但未在限定时间内匹配到窗口")
    }

    private func bestMatch(
        for item: PresetItem,
        in windows: [RuntimeWindow]
    ) -> (window: RuntimeWindow, match: WindowMatch)? {
        windows
            .map { ($0, WindowMatcher.match(item: item, window: $0.discovered)) }
            .filter { $0.1.bundleIdentifierMatched && $0.1.score >= 50 }
            .max { $0.1.score < $1.1.score }
    }

    private enum OpenError: LocalizedError {
        case applicationNotFound
        case missingResource
        case openFailed
        case unsupported

        var errorDescription: String? {
            switch self {
            case .applicationNotFound: "找不到目标应用"
            case .missingResource: "预设项目缺少资源路径或 URL"
            case .openFailed: "系统拒绝了打开请求"
            case .unsupported: "不支持的预设项目"
            }
        }
    }

    private func open(item: PresetItem) throws {
        switch item.kind {
        case .command:
            throw OpenError.unsupported
        case .url, .edgeWindow:
            guard let value = item.resourcePath, let url = URL(string: value) else {
                throw OpenError.missingResource
            }
            if let applicationURL = applicationURL(for: item) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = [url.absoluteString]
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration,
                    completionHandler: nil
                )
            } else if !NSWorkspace.shared.open(url) {
                throw OpenError.openFailed
            }
        case .file, .folder, .finderFolder:
            guard let path = item.resourcePath else { throw OpenError.missingResource }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { throw OpenError.missingResource }
            if !NSWorkspace.shared.open(url) { throw OpenError.openFailed }
        case .vscodeFolder, .vscodeWorkspace:
            guard let path = item.resourcePath else { throw OpenError.missingResource }
            guard let applicationURL = applicationURL(for: item) ??
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
                throw OpenError.applicationNotFound
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", applicationURL.path, "--args", "--new-window", path]
            try process.run()
        case .application:
            guard let applicationURL = applicationURL(for: item) else {
                throw OpenError.applicationNotFound
            }
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }
    }

    private func applicationURL(for item: PresetItem) -> URL? {
        if let path = item.applicationPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let identifier = item.applicationBundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
        return nil
    }

    private func restore(window: RuntimeWindow, layout: WindowLayout) -> Bool {
        guard AXIsProcessTrusted(), let element = accessibilityWindow(matching: window) else { return false }
        let target = denormalizedFrame(for: layout.clamped())
        var position = target.origin
        var size = target.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        if layout.bringToFront {
            let app = AXUIElementCreateApplication(window.pid)
            _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        return positionResult == .success && sizeResult == .success
    }

    private func accessibilityWindow(matching runtime: RuntimeWindow) -> AXUIElement? {
        let application = AXUIElementCreateApplication(runtime.pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement] else { return nil }

        return windows.min { lhs, rhs in
            accessibilityDistance(lhs, to: runtime) < accessibilityDistance(rhs, to: runtime)
        }.flatMap { accessibilityDistance($0, to: runtime) < 10_000 ? $0 : nil }
    }

    private func accessibilityDistance(_ element: AXUIElement, to runtime: RuntimeWindow) -> Double {
        let title: String = copyAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let titlePenalty = title == runtime.title ? 0.0 : 5_000.0
        guard let frame = accessibilityFrame(element) else { return titlePenalty + 20_000 }
        return titlePenalty
            + abs(frame.minX - runtime.bounds.minX)
            + abs(frame.minY - runtime.bounds.minY)
            + abs(frame.width - runtime.bounds.width)
            + abs(frame.height - runtime.bounds.height)
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttribute(element, kAXPositionAttribute as CFString),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute as CFString) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? T
    }

    private func normalizedLayout(for bounds: CGRect) -> WindowLayout {
        let visible = visibleFrameInCGCoordinates()
        return WindowLayout(
            screenIdentifier: NSScreen.main?.localizedName,
            normalizedX: (bounds.minX - visible.minX) / visible.width,
            normalizedY: (bounds.minY - visible.minY) / visible.height,
            normalizedWidth: bounds.width / visible.width,
            normalizedHeight: bounds.height / visible.height
        ).clamped()
    }

    private func denormalizedFrame(for layout: WindowLayout) -> CGRect {
        let visible = visibleFrameInCGCoordinates()
        return CGRect(
            x: visible.minX + layout.normalizedX * visible.width,
            y: visible.minY + layout.normalizedY * visible.height,
            width: layout.normalizedWidth * visible.width,
            height: layout.normalizedHeight * visible.height
        )
    }

    private func visibleFrameInCGCoordinates() -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return CGRect(x: 0, y: 0, width: 1_440, height: 900)
        }
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.minX,
            y: screen.frame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    private func capturedKind(bundleIdentifier: String) -> PresetItem.Kind {
        // Window-list capture does not expose a reliable document URL. Treat the
        // captured target as an application window; resource-specific entries can
        // still be added explicitly in Settings.
        return .application
    }

    private func outcome(
        _ item: PresetItem,
        _ status: PresetItemOutcome.Status,
        _ message: String
    ) -> PresetItemOutcome {
        PresetItemOutcome(
            itemID: item.id,
            displayName: item.displayName,
            status: status,
            message: message
        )
    }
}
