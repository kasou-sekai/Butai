import AppKit
import ApplicationServices
import ButaiCore
import Darwin
import Foundation

struct RuntimeWindowSnapshot {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let applicationPath: String?
    let title: String
    let bounds: CGRect
    let documentURL: String?
    let resourcePath: String?

    var discovered: DiscoveredWindow {
        DiscoveredWindow(
            bundleIdentifier: bundleIdentifier,
            title: title,
            documentURL: documentURL,
            resourcePath: resourcePath
        )
    }
}

struct AdapterHealth: Identifiable, Equatable {
    enum State { case ready, degraded, unavailable, experimental }
    let id: String
    let name: String
    let state: State
    let detail: String
}

struct FinderWindowMetadata: Decodable {
    let windowID: CGWindowID
    let title: String
    let documentURL: String
}

enum FinderWindowMetadataProvider {
    static func load(timeoutSeconds: Double = 1.5) async -> [CGWindowID: FinderWindowMetadata] {
        let script = """
        const finder = Application('Finder');
        const result = finder.windows().map(window => {
          let documentURL = '';
          try { documentURL = String(window.target().url()); } catch (_) {}
          return {
            windowID: Number(window.id()),
            title: String(window.name()),
            documentURL: documentURL
          };
        });
        JSON.stringify(result);
        """
        guard let result = try? await ProcessRunner.runCapturingOutput(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", script],
            timeoutSeconds: timeoutSeconds
        ), result.status == 0,
        let metadata = try? JSONDecoder().decode([FinderWindowMetadata].self, from: result.standardOutput) else {
            return [:]
        }
        return Dictionary(metadata.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

enum AdapterOpenError: LocalizedError {
    case applicationNotFound(String)
    case missingResource
    case resourceUnavailable(String)
    case launchFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .applicationNotFound(name): "找不到 \(name)"
        case .missingResource: "预设项目缺少路径或 URL"
        case let .resourceUnavailable(value): "资源不可用：\(value)"
        case let .launchFailed(message): message
        case let .unsupported(message): message
        }
    }
}

@MainActor
protocol ApplicationAdapter {
    var id: String { get }
    var displayName: String { get }
    func supports(item: PresetItem) -> Bool
    func supports(window: RuntimeWindowSnapshot) -> Bool
    func capture(window: RuntimeWindowSnapshot, layout: WindowLayout, sortOrder: Int) -> PresetItem?
    func open(item: PresetItem) async throws
    func health() -> AdapterHealth
}

@MainActor
final class AdapterRegistry {
    let adapters: [any ApplicationAdapter]

    init(adapters: [any ApplicationAdapter] = [
        FinderAdapter(), VSCodeAdapter(), EdgeAdapter(), ChatGPTAdapter()
    ]) {
        self.adapters = adapters
    }

    func adapter(for item: PresetItem) -> (any ApplicationAdapter)? {
        adapters.first { $0.supports(item: item) }
    }

    func capture(window: RuntimeWindowSnapshot, layout: WindowLayout, sortOrder: Int) -> PresetItem? {
        adapters.first(where: { $0.supports(window: window) })?
            .capture(window: window, layout: layout, sortOrder: sortOrder)
    }

    var health: [AdapterHealth] { adapters.map { $0.health() } }
}

@MainActor
private final class FinderAdapter: ApplicationAdapter {
    let id = "finder"
    let displayName = "Finder"

    func supports(item: PresetItem) -> Bool {
        item.kind == .finderFolder
    }

    func supports(window: RuntimeWindowSnapshot) -> Bool {
        window.bundleIdentifier == "com.apple.finder"
    }

    func capture(window: RuntimeWindowSnapshot, layout: WindowLayout, sortOrder: Int) -> PresetItem? {
        guard let path = window.resourcePath else { return nil }
        return PresetItem(
            kind: .finderFolder,
            applicationBundleIdentifier: window.bundleIdentifier,
            applicationPath: window.applicationPath,
            resourcePath: path,
            displayName: window.title.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : window.title,
            openPolicy: .newWindowRequired,
            matchRules: [WindowMatchRule(kind: .resourcePath, value: path, weight: 45)]
                + (window.title.isEmpty ? [] : [
                    WindowMatchRule(kind: .titleExact, value: window.title, weight: 15)
                ]),
            windowLayout: layout,
            sortOrder: sortOrder
        )
    }

    func open(item: PresetItem) async throws {
        guard let path = item.resourcePath else { throw AdapterOpenError.missingResource }
        guard FileManager.default.fileExists(atPath: path) else {
            throw AdapterOpenError.resourceUnavailable(path)
        }
        if item.openPolicy == .reusePreferred {
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else {
                throw AdapterOpenError.launchFailed("Finder 拒绝了打开请求")
            }
            return
        }

        try await ProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: [
                "-e", "on run argv",
                "-e", "set targetFolder to (POSIX file (item 1 of argv)) as alias",
                "-e", "tell application \"Finder\"",
                "-e", "set createdWindow to make new Finder window",
                "-e", "set target of createdWindow to targetFolder",
                "-e", "activate",
                "-e", "end tell",
                "-e", "end run",
                path
            ],
            failureMessage: "无法创建 Finder 新窗口；请检查自动化权限"
        )
    }

    func health() -> AdapterHealth {
        AdapterHealth(
            id: id,
            name: displayName,
            state: AXIsProcessTrusted() ? .ready : .degraded,
            detail: AXIsProcessTrusted() ? "可读取路径并恢复窗口" : "需要辅助功能权限读取文件夹路径"
        )
    }
}

@MainActor
private final class VSCodeAdapter: ApplicationAdapter {
    let id = "vscode"
    let displayName = "Visual Studio Code"
    private let bundleIdentifiers = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"
    ]

    func supports(item: PresetItem) -> Bool {
        item.kind == .vscodeFolder || item.kind == .vscodeWorkspace
    }

    func supports(window: RuntimeWindowSnapshot) -> Bool {
        bundleIdentifiers.contains(window.bundleIdentifier)
    }

    func capture(window: RuntimeWindowSnapshot, layout: WindowLayout, sortOrder: Int) -> PresetItem? {
        guard let path = workspacePath(from: window) else { return nil }
        let kind: PresetItem.Kind = path.hasSuffix(".code-workspace") ? .vscodeWorkspace : .vscodeFolder
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return PresetItem(
            kind: kind,
            applicationBundleIdentifier: window.bundleIdentifier,
            applicationPath: window.applicationPath,
            resourcePath: path,
            displayName: name,
            openPolicy: .newWindowRequired,
            matchRules: [
                WindowMatchRule(kind: .resourcePath, value: path, weight: 40),
                WindowMatchRule(kind: .titlePrefix, value: name, weight: 35)
            ],
            windowLayout: layout,
            sortOrder: sortOrder
        )
    }

    func open(item: PresetItem) async throws {
        guard let path = item.resourcePath else { throw AdapterOpenError.missingResource }
        guard FileManager.default.fileExists(atPath: path) else {
            throw AdapterOpenError.resourceUnavailable(path)
        }
        guard let applicationURL = AdapterApplications.url(for: item, candidates: bundleIdentifiers) else {
            throw AdapterOpenError.applicationNotFound(displayName)
        }
        try await ProcessRunner.run(
            executable: "/usr/bin/open",
            arguments: ["-na", applicationURL.path, "--args", "--new-window", path],
            failureMessage: "VS Code 未能创建项目窗口"
        )
    }

    func health() -> AdapterHealth {
        let installed = bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return AdapterHealth(
            id: id,
            name: displayName,
            state: installed ? .ready : .unavailable,
            detail: installed ? "支持 Stable、Insiders 和 VSCodium 新窗口" : "未检测到支持的 VS Code 发行版"
        )
    }

    private func workspacePath(from window: RuntimeWindowSnapshot) -> String? {
        guard let path = window.resourcePath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue || path.hasSuffix(".code-workspace") ? path : nil
    }
}

@MainActor
private final class EdgeAdapter: ApplicationAdapter {
    let id = "edge"
    let displayName = "Microsoft Edge"
    private let bundleIdentifier = "com.microsoft.edgemac"

    func supports(item: PresetItem) -> Bool {
        item.kind == .edgeWindow
    }

    func supports(window: RuntimeWindowSnapshot) -> Bool {
        window.bundleIdentifier == bundleIdentifier
    }

    func capture(window: RuntimeWindowSnapshot, layout: WindowLayout, sortOrder: Int) -> PresetItem? {
        guard let value = window.documentURL, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return PresetItem(
            kind: .edgeWindow,
            applicationBundleIdentifier: bundleIdentifier,
            applicationPath: window.applicationPath,
            resourcePath: value,
            displayName: window.title.isEmpty ? value : window.title,
            openPolicy: .newWindowRequired,
            matchRules: [WindowMatchRule(kind: .documentURL, value: value, weight: 45)]
                + (window.title.isEmpty ? [] : [
                    WindowMatchRule(kind: .titleExact, value: window.title, weight: 15)
                ]),
            windowLayout: layout,
            sortOrder: sortOrder
        )
    }

    func open(item: PresetItem) async throws {
        var candidates = item.additionalResourcePaths ?? []
        if let primary = item.resourcePath { candidates.insert(primary, at: 0) }
        let values = candidates.filter { value in
            guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        guard !values.isEmpty else { throw AdapterOpenError.missingResource }
        guard let applicationURL = AdapterApplications.url(for: item, candidates: [bundleIdentifier]) else {
            throw AdapterOpenError.applicationNotFound(displayName)
        }
        var arguments = ["-na", applicationURL.path, "--args", "--new-window"]
        if let profile = item.profileIdentifier, !profile.isEmpty {
            arguments.append("--profile-directory=\(profile)")
        }
        arguments.append(contentsOf: values)
        try await ProcessRunner.run(
            executable: "/usr/bin/open",
            arguments: arguments,
            failureMessage: "Edge 未能创建新窗口"
        )
    }

    func health() -> AdapterHealth {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        return AdapterHealth(
            id: id,
            name: displayName,
            state: installed ? .ready : .unavailable,
            detail: installed ? "支持新窗口、多个 URL 和 Profile" : "未安装 Microsoft Edge"
        )
    }
}

@MainActor
private final class ChatGPTAdapter: ApplicationAdapter {
    let id = "chatgpt"
    let displayName = "ChatGPT / Codex（实验性）"
    private let bundleIdentifiers = ["com.openai.codex", "com.openai.chat"]

    func supports(item: PresetItem) -> Bool {
        item.kind == .chatGPTWindow
    }

    func supports(window: RuntimeWindowSnapshot) -> Bool {
        bundleIdentifiers.contains(window.bundleIdentifier)
    }

    func capture(window: RuntimeWindowSnapshot, layout: WindowLayout, sortOrder: Int) -> PresetItem? {
        PresetItem(
            kind: .chatGPTWindow,
            applicationBundleIdentifier: window.bundleIdentifier,
            applicationPath: window.applicationPath,
            displayName: window.title.isEmpty ? "ChatGPT / Codex" : window.title,
            openPolicy: .reusePreferred,
            matchRules: window.title.isEmpty ? [] : [
                WindowMatchRule(kind: .titleExact, value: window.title, weight: 35)
            ],
            windowLayout: layout,
            sortOrder: sortOrder
        )
    }

    func open(item: PresetItem) async throws {
        // Prefer the current unified ChatGPT/Codex bundle over a stale path or the
        // legacy ChatGPT bundle saved by older Butai releases.
        guard let applicationURL = bundleIdentifiers.lazy.compactMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).first ?? AdapterApplications.url(for: item, candidates: bundleIdentifiers) else {
            throw AdapterOpenError.applicationNotFound("ChatGPT / Codex")
        }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    func health() -> AdapterHealth {
        let installed = bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return AdapterHealth(
            id: id,
            name: displayName,
            state: installed ? .experimental : .unavailable,
            detail: installed ? "可启动或激活 Codex；新窗口支持暂缓，不保证打开指定聊天" : "未安装 ChatGPT / Codex"
        )
    }
}

private enum AdapterApplications {
    static func url(for item: PresetItem, candidates: [String]) -> URL? {
        if let path = item.applicationPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let identifier = item.applicationBundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        return candidates.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }
}

private enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    static func run(
        executable: String,
        arguments: [String],
        failureMessage: String,
        timeoutSeconds: Double = 15
    ) async throws {
        let result = try await runCapturingOutput(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )
        guard result.status == 0 else { throw AdapterOpenError.launchFailed(failureMessage) }
    }

    static func runCapturingOutput(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double
    ) async throws -> Result {
        try await Task.detached {
            let box = ProcessBox()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            box.process.executableURL = URL(fileURLWithPath: executable)
            box.process.arguments = arguments
            box.process.standardOutput = outputPipe
            box.process.standardError = errorPipe
            try box.process.run()

            let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0.1))
            while box.process.isRunning, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if box.process.isRunning {
                box.process.terminate()
                try? await Task.sleep(for: .milliseconds(100))
            }
            if box.process.isRunning {
                _ = Darwin.kill(box.process.processIdentifier, SIGKILL)
                box.process.waitUntilExit()
            }

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return Result(
                status: box.process.terminationStatus,
                standardOutput: output,
                standardError: error
            )
        }.value
    }
}
