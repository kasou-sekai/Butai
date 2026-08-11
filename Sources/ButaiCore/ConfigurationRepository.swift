import Foundation

public actor ConfigurationRepository {
    public enum RepositoryError: Error, Equatable {
        case unsupportedSchema(Int)
    }

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
        guard configuration.schemaVersion == 1 else {
            throw RepositoryError.unsupportedSchema(configuration.schemaVersion)
        }

        let directory = configurationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: configurationURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: configurationURL, to: backupURL)
        }

        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL, options: [.atomic, .completeFileProtectionUnlessOpen])

        if !fileManager.fileExists(atPath: backupURL.path) {
            try data.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    private func decode(_ url: URL) throws -> ButaiConfiguration {
        let configuration = try decoder.decode(ButaiConfiguration.self, from: Data(contentsOf: url))
        guard configuration.schemaVersion == 1 else {
            throw RepositoryError.unsupportedSchema(configuration.schemaVersion)
        }
        return configuration
    }
}
