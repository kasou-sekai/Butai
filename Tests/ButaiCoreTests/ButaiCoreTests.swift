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

    @Test("Historical unused settings are discarded")
    func historicalUnusedSettingsAreDiscarded() throws {
        let historicalData = Data(
            #"{"overlayHorizontalOffset":240,"overlayVerticalOffset":18,"feedbackDuration":9,"capsLockShortcutsEnabled":true,"switchingAction":"completePreset"}"#.utf8
        )
        let historicalDecoded = try JSONDecoder().decode(AppSettings.self, from: historicalData)
        let reencoded = try JSONEncoder().encode(historicalDecoded)
        let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])

        #expect(historicalDecoded.overlayVerticalOffset == 18)
        #expect(object["overlayHorizontalOffset"] == nil)
        #expect(object["feedbackDuration"] == nil)
        #expect(object["capsLockShortcutsEnabled"] == nil)
        #expect(object["switchingAction"] == nil)
    }

    @Test("Empty decoded workspace lists recover to a usable default")
    func emptyWorkspaceListRecovers() {
        let configuration = ButaiConfiguration(workspaces: [])
        let profile = DisplayWorkspaceProfile(displayIdentifier: "display-A", workspaces: [])

        #expect(configuration.workspaces.count == 1)
        #expect(configuration.workspaces[0].order == 1)
        #expect(profile.workspaces.count == 1)
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

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let configurationMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let backupMode = try FileManager.default.attributesOfItem(atPath: url.appendingPathExtension("backup").path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(configurationMode?.intValue == 0o600)
        #expect(backupMode?.intValue == 0o600)
    }

    @Test("A newer primary schema is never silently downgraded to its backup")
    func newerSchemaDoesNotFallBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("configuration.json")
        let repository = ConfigurationRepository(configurationURL: url)
        try await repository.save(.initial(workspaceCount: 2))

        var future = ButaiConfiguration.initial(workspaceCount: 3)
        future.schemaVersion = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(future).write(to: url, options: .atomic)

        do {
            _ = try await repository.load()
            Issue.record("Expected the unsupported primary schema to be rejected")
        } catch let error as ConfigurationRepository.RepositoryError {
            #expect(error == .unsupportedSchema(99))
        }
    }

    @Test("Display profiles isolate names and retain hidden workspaces")
    func displayProfilesRemainBound() {
        var firstDisplay = DisplayWorkspaceProfile.new(displayIdentifier: "display-A", workspaceCount: 4)
        var firstVisible = firstDisplay.visibleWorkspaces(count: 2)
        firstVisible[0].name = "主屏开发"
        firstDisplay.updateVisibleWorkspaces(firstVisible)

        var secondDisplay = DisplayWorkspaceProfile.new(displayIdentifier: "display-B", workspaceCount: 2)
        var secondVisible = secondDisplay.visibleWorkspaces(count: 2)
        secondVisible[0].name = "副屏会议"
        secondDisplay.updateVisibleWorkspaces(secondVisible)

        #expect(firstDisplay.workspaces[0].name == "主屏开发")
        #expect(firstDisplay.workspaces.count == 4)
        #expect(firstDisplay.workspaces[2].name == "工作区 3")
        #expect(secondDisplay.workspaces[0].name == "副屏会议")
        #expect(secondDisplay.workspaces[0].name != firstDisplay.workspaces[0].name)
    }

    @Test("Display profiles survive configuration persistence")
    func displayProfilesPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConfigurationRepository(
            configurationURL: directory.appendingPathComponent("configuration.json")
        )
        let first = DisplayWorkspaceProfile(
            displayIdentifier: "display-A",
            workspaces: [Workspace(order: 1, name: "主屏")]
        )
        let second = DisplayWorkspaceProfile(
            displayIdentifier: "display-B",
            workspaces: [Workspace(order: 1, name: "副屏")]
        )
        let configuration = ButaiConfiguration(
            workspaces: first.workspaces,
            displayProfiles: [first, second]
        )

        try await repository.save(configuration)
        let loaded = try await repository.load()

        #expect(loaded?.schemaVersion == 2)
        #expect(loaded?.displayProfiles.map(\.displayIdentifier) == ["display-A", "display-B"])
        #expect(loaded?.displayProfiles.first?.workspaces.first?.name == "主屏")
        #expect(loaded?.displayProfiles.last?.workspaces.first?.name == "副屏")
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

    @Test("Window matching normalizes file paths and safe URL variants")
    func normalizedResourceMatching() {
        let folder = PresetItem(
            kind: .finderFolder,
            applicationBundleIdentifier: "com.apple.finder",
            resourcePath: "/tmp/Folder Name/",
            displayName: "Folder Name",
            matchRules: [WindowMatchRule(kind: .resourcePath, value: "/tmp/Folder Name/", weight: 45)]
        )
        let finderWindow = DiscoveredWindow(
            bundleIdentifier: "com.apple.finder",
            title: "Folder Name",
            resourcePath: "file:///tmp/Folder%20Name"
        )
        let webItem = PresetItem(
            kind: .edgeWindow,
            applicationBundleIdentifier: "com.microsoft.edgemac",
            displayName: "Example",
            matchRules: [WindowMatchRule(kind: .documentURL, value: "https://EXAMPLE.com:443/path", weight: 45)]
        )
        let edgeWindow = DiscoveredWindow(
            bundleIdentifier: "com.microsoft.edgemac",
            title: "Example",
            documentURL: "https://example.com/path"
        )

        #expect(WindowMatcher.isAcceptable(item: folder, match: WindowMatcher.match(item: folder, window: finderWindow)))
        #expect(WindowMatcher.isAcceptable(item: webItem, match: WindowMatcher.match(item: webItem, window: edgeWindow)))
    }

    @Test("Invalid or oversized title regex rules fail closed")
    func unsafeRegexRules() {
        let invalid = PresetItem(
            kind: .application,
            applicationBundleIdentifier: "com.example.App",
            displayName: "App",
            matchRules: [WindowMatchRule(kind: .titleRegex, value: "(", weight: 45)]
        )
        let oversized = PresetItem(
            kind: .application,
            applicationBundleIdentifier: "com.example.App",
            displayName: "App",
            matchRules: [WindowMatchRule(kind: .titleRegex, value: String(repeating: "a", count: 513), weight: 45)]
        )
        let catastrophic = PresetItem(
            kind: .application,
            applicationBundleIdentifier: "com.example.App",
            displayName: "App",
            matchRules: [WindowMatchRule(kind: .titleRegex, value: "^(a+)+$", weight: 45)]
        )
        let window = DiscoveredWindow(bundleIdentifier: "com.example.App", title: "aaaa")

        #expect(!WindowMatcher.isAcceptable(item: invalid, match: WindowMatcher.match(item: invalid, window: window)))
        #expect(!WindowMatcher.isAcceptable(item: oversized, match: WindowMatcher.match(item: oversized, window: window)))
        #expect(!WindowMatcher.isAcceptable(item: catastrophic, match: WindowMatcher.match(item: catastrophic, window: window)))
    }

    @Test("Window matching requires an application identity and bounds rule weights")
    func matchingIdentityAndWeightBounds() {
        let unidentified = PresetItem(
            kind: .application,
            displayName: "Untargeted",
            matchRules: [WindowMatchRule(kind: .titleExact, value: "Document", weight: Int.max)]
        )
        let identified = PresetItem(
            kind: .application,
            applicationBundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            matchRules: [WindowMatchRule(kind: .titleExact, value: "Document", weight: Int.max)]
        )
        let window = DiscoveredWindow(bundleIdentifier: "com.example.Editor", title: "Document")

        #expect(!WindowMatcher.isAcceptable(
            item: unidentified,
            match: WindowMatcher.match(item: unidentified, window: window)
        ))
        #expect(WindowMatcher.match(item: identified, window: window).score == 150)
    }

    @Test("Layout clamping rejects non-finite geometry")
    func nonFiniteLayoutClamping() {
        let layout = WindowLayout(
            normalizedX: .nan,
            normalizedY: .infinity,
            normalizedWidth: -.infinity,
            normalizedHeight: .nan
        ).clamped()

        #expect(layout.normalizedX == 0)
        #expect(layout.normalizedY == 0)
        #expect(layout.normalizedWidth == 1)
        #expect(layout.normalizedHeight == 1)
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
