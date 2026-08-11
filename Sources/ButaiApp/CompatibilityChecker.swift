import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct CompatibilityCheck: Identifiable {
    enum State { case pass, warning, failure }
    let id: String
    let title: String
    let detail: String
    let state: State
    let repairURL: URL?
}

enum CompatibilityChecker {
    static func checks() -> [CompatibilityCheck] {
        let accessibility = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        let post = CGPreflightPostEventAccess()
        let displayCount = NSScreen.screens.count
        let versionOK = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )
        let autoReorder = preferenceBool(key: "mru-spaces", app: "com.apple.dock")
        let stageManager = preferenceBool(key: "GloballyEnabled", app: "com.apple.WindowManager") ??
            preferenceBool(key: "globally-enabled", app: "com.apple.WindowManager")

        return [
            CompatibilityCheck(
                id: "system", title: "macOS 14 或更高版本",
                detail: ProcessInfo.processInfo.operatingSystemVersionString,
                state: versionOK ? .pass : .failure, repairURL: nil
            ),
            CompatibilityCheck(
                id: "display", title: "单显示器",
                detail: "检测到 \(displayCount) 台显示器",
                state: displayCount == 1 ? .pass : .warning, repairURL: nil
            ),
            CompatibilityCheck(
                id: "accessibility", title: "辅助功能权限",
                detail: accessibility ? "已授权" : "桌面切换、读取、聚焦和调整窗口所必需",
                state: accessibility ? .pass : .failure,
                repairURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ),
            CompatibilityCheck(
                id: "input", title: "输入监听权限",
                detail: listen ? "已授权" : "用于全局快捷键",
                state: listen ? .pass : .warning,
                repairURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            ),
            CompatibilityCheck(
                id: "post", title: "桌面导航事件权限",
                detail: post ? "已授权" : "系统可能返回假阴性；以辅助功能权限为准",
                state: post ? .pass : .warning,
                repairURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ),
            CompatibilityCheck(
                id: "reorder", title: "关闭自动重新排列 Spaces",
                detail: autoReorder == nil ? "无法自动读取，请手动确认" : (autoReorder! ? "当前可能已开启" : "已关闭"),
                state: autoReorder == false ? .pass : .warning,
                repairURL: URL(string: "x-apple.systempreferences:com.apple.preference.dock")
            ),
            CompatibilityCheck(
                id: "stageManager", title: "关闭台前调度",
                detail: stageManager == nil ? "无法自动读取，请手动确认" : (stageManager! ? "当前可能已开启" : "已关闭"),
                state: stageManager == false ? .pass : .warning,
                repairURL: URL(string: "x-apple.systempreferences:com.apple.Window-Settings.extension")
            )
        ]
    }

    static func requestAccessibility() {
        // The C header exposes kAXTrustedCheckOptionPrompt as mutable global state,
        // which Swift 6 correctly refuses to read from concurrent contexts.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    private static func preferenceBool(key: String, app: String) -> Bool? {
        CFPreferencesCopyAppValue(key as CFString, app as CFString) as? Bool
    }
}
