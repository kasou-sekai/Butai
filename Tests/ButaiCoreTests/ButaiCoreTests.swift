import Foundation
import Testing
@testable import ButaiCore

@Suite("Butai core")
struct ButaiCoreTests {
    @Test("Initial configuration clamps workspace count")
    func initialConfiguration() {
        let empty = ButaiConfiguration.initial(workspaceCount: 0)
        let excessive = ButaiConfiguration.initial(workspaceCount: 20)

        #expect(empty.workspaces.count == 1)
        #expect(excessive.workspaces.count == 9)
        #expect(excessive.workspaces.map(\.order) == Array(1...9))
    }

    @Test("Configuration round trips and writes a backup")
    func persistenceRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configuration.json")
        let repository = ConfigurationRepository(configurationURL: url)
        var configuration = ButaiConfiguration.initial(workspaceCount: 3)
        configuration.workspaces[0].presets = [
            Preset(
                workspaceID: configuration.workspaces[0].id,
                name: "开发预设",
                items: [
                    PresetItem(
                        kind: .application,
                        applicationBundleIdentifier: "com.apple.TextEdit",
                        displayName: "TextEdit",
                        windowLayout: WindowLayout(
                            normalizedX: 0.1,
                            normalizedY: 0.2,
                            normalizedWidth: 0.5,
                            normalizedHeight: 0.6
                        )
                    ),
                    PresetItem(
                        kind: .edgeWindow,
                        applicationBundleIdentifier: "com.microsoft.edgemac",
                        resourcePath: "https://example.com",
                        additionalResourcePaths: ["https://example.org"],
                        profileIdentifier: "Profile 1",
                        displayName: "Research",
                        openPolicy: .newWindowRequired
                    )
                ]
            )
        ]

        try await repository.save(configuration)
        let firstVersion = configuration
        configuration.workspaces[0].name = "开发"
        try await repository.save(configuration)
        let loaded = try await repository.load()
        let backupRepository = ConfigurationRepository(configurationURL: url.appendingPathExtension("backup"))
        let backup = try await backupRepository.load()

        #expect(loaded?.schemaVersion == configuration.schemaVersion)
        #expect(loaded?.workspaces.map(\.id) == configuration.workspaces.map(\.id))
        #expect(loaded?.workspaces.map(\.name) == configuration.workspaces.map(\.name))
        #expect(loaded?.settings == configuration.settings)
        #expect(loaded?.workspaces[0].presets.map(\.id) == configuration.workspaces[0].presets.map(\.id))
        #expect(loaded?.workspaces[0].presets.map(\.name) == configuration.workspaces[0].presets.map(\.name))
        #expect(loaded?.workspaces[0].presets.first?.items == configuration.workspaces[0].presets.first?.items)
        #expect(backup?.workspaces.map(\.id) == firstVersion.workspaces.map(\.id))
        #expect(backup?.workspaces.map(\.name) == firstVersion.workspaces.map(\.name))
    }

    @Test("Preset execution report counts successes and issues")
    func presetExecutionReport() {
        let presetID = UUID()
        let outcomes = [
            PresetItemOutcome(
                itemID: UUID(),
                displayName: "Ready",
                status: .ready,
                message: "已有窗口"
            ),
            PresetItemOutcome(
                itemID: UUID(),
                displayName: "Missing",
                status: .applicationNotFound,
                message: "找不到应用"
            )
        ]
        let report = PresetExecutionReport(
            presetID: presetID,
            presetName: "开发预设",
            mode: .complete,
            outcomes: outcomes,
            startedAt: .distantPast,
            finishedAt: .now
        )

        #expect(report.successCount == 1)
        #expect(report.issueCount == 1)
        #expect(report.summary == "开发预设已补全：1 成功，1 需要处理")
    }

    @Test("Layout remains inside visible normalized bounds")
    func layoutClamping() {
        let layout = WindowLayout(
            normalizedX: -0.5,
            normalizedY: 0.95,
            normalizedWidth: 1.4,
            normalizedHeight: 0.01
        ).clamped()

        #expect(layout.normalizedX == 0)
        #expect(layout.normalizedWidth == 1)
        #expect(layout.normalizedHeight == 0.08)
        #expect(layout.normalizedY == 0.92)
    }

    @Test("Window matching requires more than a shared bundle id for high confidence")
    func matchingConfidence() {
        let item = PresetItem(
            kind: .vscodeFolder,
            applicationBundleIdentifier: "com.microsoft.VSCode",
            displayName: "Butai",
            matchRules: [
                WindowMatchRule(kind: .resourcePath, value: "/repo/Butai", weight: 35)
            ]
        )
        let correct = DiscoveredWindow(
            bundleIdentifier: "com.microsoft.VSCode",
            title: "Butai — Visual Studio Code",
            resourcePath: "/repo/Butai"
        )
        let other = DiscoveredWindow(
            bundleIdentifier: "com.microsoft.VSCode",
            title: "Other — Visual Studio Code",
            resourcePath: "/repo/Other"
        )

        #expect(WindowMatcher.match(item: item, window: correct).confidence == .high)
        #expect(WindowMatcher.match(item: item, window: other).confidence == .medium)
        #expect(WindowMatcher.isAcceptable(item: item, match: WindowMatcher.match(item: item, window: correct)))
        #expect(!WindowMatcher.isAcceptable(item: item, match: WindowMatcher.match(item: item, window: other)))
    }

    @Test("Generic applications may reuse bundle matches while resource items may not")
    func resourceMatchingThreshold() {
        let generic = PresetItem(
            kind: .application,
            applicationBundleIdentifier: "com.example.Editor",
            displayName: "Editor"
        )
        let folder = PresetItem(
            kind: .finderFolder,
            applicationBundleIdentifier: "com.apple.finder",
            resourcePath: "/tmp/Target",
            displayName: "Target",
            matchRules: [WindowMatchRule(kind: .resourcePath, value: "/tmp/Target", weight: 45)]
        )
        let genericWindow = DiscoveredWindow(bundleIdentifier: "com.example.Editor", title: "Anything")
        let wrongFolder = DiscoveredWindow(
            bundleIdentifier: "com.apple.finder",
            title: "Other",
            resourcePath: "/tmp/Other"
        )

        #expect(WindowMatcher.isAcceptable(
            item: generic,
            match: WindowMatcher.match(item: generic, window: genericWindow)
        ))
        #expect(!WindowMatcher.isAcceptable(
            item: folder,
            match: WindowMatcher.match(item: folder, window: wrongFolder)
        ))
    }

    @Test("Navigation intent validates bounds")
    func navigationIntent() throws {
        let intent = try NavigationIntent(currentOrder: 2, targetOrder: 5, workspaceCount: 6)
        #expect(intent.step == 1)
        #expect(intent.stepCount == 3)
        #expect(throws: SpaceNavigationError.invalidTarget) {
            try NavigationIntent(currentOrder: 0, targetOrder: 2, workspaceCount: 6)
        }
    }
}
