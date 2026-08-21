import Foundation

public actor ConfigurationRepository {
    public enum RepositoryError: Error, Equatable {
        case unsupportedSchema(Int)
        case configurationTooLarge(Int)
    }

    private static let maximumConfigurationBytes = 10 * 1_024 * 1_024
    private static let supportedSchemaVersions: Set<Int> = [1, 2]

    public let configurationURL: URL
    public let backupURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configurationURL: URL, fileManager: FileManager = .default) {
        self.configurationURL = configurationURL
        self.backupURL = configurationURL.appendingPathExtension("backup")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .secondsSince1970
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .secondsSince1970
    }

    public static func defaultRepository() -> ConfigurationRepository {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Butai", isDirectory: true)
        return ConfigurationRepository(configurationURL: root.appendingPathComponent("configuration.json"))
    }

    public func load() throws -> ButaiConfiguration? {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        do {
            return try decode(configurationURL)
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path) else { throw error }
            return try decode(backupURL)
        }
    }

    public func save(_ configuration: ButaiConfiguration) throws {
        guard Self.supportedSchemaVersions.contains(configuration.schemaVersion) else {
            throw RepositoryError.unsupportedSchema(configuration.schemaVersion)
        }

        let directory = configurationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: configurationURL.path),
           let previousData = try? checkedData(contentsOf: configurationURL) {
            try previousData.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }

        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumConfigurationBytes else {
            throw RepositoryError.configurationTooLarge(data.count)
        }
        try data.write(to: configurationURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)

        if !fileManager.fileExists(atPath: backupURL.path) {
            try data.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
    }

    private func decode(_ url: URL) throws -> ButaiConfiguration {
        let configuration = try decoder.decode(ButaiConfiguration.self, from: checkedData(contentsOf: url))
        guard Self.supportedSchemaVersions.contains(configuration.schemaVersion) else {
            throw RepositoryError.unsupportedSchema(configuration.schemaVersion)
        }
        return configuration
    }

    private func checkedData(contentsOf url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadInvalidFileName) }
        if let size = values.fileSize, size > Self.maximumConfigurationBytes {
            throw RepositoryError.configurationTooLarge(size)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumConfigurationBytes else {
            throw RepositoryError.configurationTooLarge(data.count)
        }
        return data
    }
}
