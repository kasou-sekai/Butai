import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct RequiredPermission: Identifiable {
    let id: String
    let title: String
    let detail: String
}

enum CompatibilityChecker {
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    static var accessibilityIsGranted: Bool { AXIsProcessTrusted() }

    static var missingRequiredPermissions: [RequiredPermission] {
        var missing: [RequiredPermission] = []
        if !accessibilityIsGranted {
            missing.append(
                RequiredPermission(
                    id: "accessibility",
                    title: "辅助功能权限",
                    detail: "用于切换桌面、读取窗口，以及调整窗口位置和大小。"
                )
            )
        }
        if !CGPreflightPostEventAccess() {
            missing.append(
                RequiredPermission(
                    id: "postEvent",
                    title: "桌面导航事件权限",
                    detail: "用于发送 macOS 桌面切换快捷键。"
                )
            )
        }
        return missing
    }

    static func requestRequiredPermissions() {
        guard !missingRequiredPermissions.isEmpty else { return }
        requestAccessibility()
    }

    static func requestAccessibility() {
        // The C header exposes kAXTrustedCheckOptionPrompt as mutable global state,
        // which Swift 6 correctly refuses to read from concurrent contexts.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
    }
}
