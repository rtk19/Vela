import Foundation

struct UserDataBackupSummary: Equatable {
    let exportedAt: Date
    let appVersion: String
    let fileCount: Int
}

struct UserDataBackupService {
    static let currentSchemaVersion = 1

    private struct Archive: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let appVersion: String
        let preferencesPropertyList: Data
        let applicationSupportFiles: [ArchivedFile]
    }

    private struct ArchivedFile: Codable {
        let relativePath: String
        let contents: Data
    }

    private let fileManager: FileManager
    private let applicationSupportDirectory: URL
    private let userDefaults: UserDefaults
    private let preferencesDomain: String
    private let appVersion: String

    init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        preferencesDomain: String,
        appVersion: String
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.preferencesDomain = preferencesDomain
        self.appVersion = appVersion
    }

    func exportData(now: Date = Date()) throws -> Data {
        let preferences = userDefaults.persistentDomain(forName: preferencesDomain) ?? [:]
        let preferencesData = try PropertyListSerialization.data(
            fromPropertyList: preferences,
            format: .binary,
            options: 0
        )
        let archive = Archive(
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: now,
            appVersion: appVersion,
            preferencesPropertyList: preferencesData,
            applicationSupportFiles: try archivedFiles()
        )
        return try Self.makeEncoder().encode(archive)
    }

    func summary(for data: Data) throws -> UserDataBackupSummary {
        let archive = try validatedArchive(from: data)
        return UserDataBackupSummary(
            exportedAt: archive.exportedAt,
            appVersion: archive.appVersion,
            fileCount: archive.applicationSupportFiles.count
        )
    }

    func restore(from data: Data) throws {
        let archive = try validatedArchive(from: data)
        let restoredPreferences = try Self.preferences(from: archive.preferencesPropertyList)
        let parent = applicationSupportDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(
            path: ".Vela-import-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let rollback = parent.appending(
            path: ".Vela-rollback-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for file in archive.applicationSupportFiles {
                let destination = staging.appending(path: restoredRelativePath(file.relativePath))
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.contents.write(to: destination, options: .atomic)
            }

            let hadExistingDirectory = fileManager.fileExists(atPath: applicationSupportDirectory.path)
            if hadExistingDirectory {
                try fileManager.moveItem(at: applicationSupportDirectory, to: rollback)
            }
            do {
                try fileManager.moveItem(at: staging, to: applicationSupportDirectory)
            } catch {
                if hadExistingDirectory {
                    try? fileManager.moveItem(at: rollback, to: applicationSupportDirectory)
                }
                throw error
            }

            userDefaults.removePersistentDomain(forName: preferencesDomain)
            userDefaults.setPersistentDomain(restoredPreferences, forName: preferencesDomain)
            if hadExistingDirectory {
                try? fileManager.removeItem(at: rollback)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func archivedFiles() throws -> [ArchivedFile] {
        let resolvedDirectory = applicationSupportDirectory.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolvedDirectory.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: resolvedDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }

        var result: [ArchivedFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let resolvedURL = url.resolvingSymlinksInPath()
            let rootPrefix = resolvedDirectory.path + "/"
            guard resolvedURL.path.hasPrefix(rootPrefix) else {
                throw UserDataBackupError.invalidFile
            }
            let relativePath = String(resolvedURL.path.dropFirst(rootPrefix.count))
            result.append(ArchivedFile(relativePath: relativePath, contents: try Data(contentsOf: url)))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func validatedArchive(from data: Data) throws -> Archive {
        let archive: Archive
        do {
            archive = try Self.makeDecoder().decode(Archive.self, from: data)
        } catch {
            throw UserDataBackupError.invalidFile
        }
        guard archive.schemaVersion == Self.currentSchemaVersion else {
            throw UserDataBackupError.unsupportedVersion(archive.schemaVersion)
        }
        _ = try Self.preferences(from: archive.preferencesPropertyList)

        var paths = Set<String>()
        for file in archive.applicationSupportFiles {
            let relativePath = restoredRelativePath(file.relativePath)
            guard Self.isSafeRelativePath(relativePath), paths.insert(relativePath).inserted else {
                throw UserDataBackupError.invalidFile
            }
        }
        return archive
    }

    private func restoredRelativePath(_ path: String) -> String {
        // Version 1 backups made on iOS could mix `/var` with `/private/var` while
        // calculating a relative path. That stripped eight extra characters from
        // `BetterStreamflix` and archived every file below an `eamflix` folder.
        // Keep those already-exported backups importable after fixing new exports.
        let legacyPrefix = "eamflix/"
        guard applicationSupportDirectory.lastPathComponent == "BetterStreamflix",
              path.hasPrefix(legacyPrefix) else { return path }
        return String(path.dropFirst(legacyPrefix.count))
    }

    private static func preferences(from data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw UserDataBackupError.invalidFile
        }
        guard let preferences = value as? [String: Any] else {
            throw UserDataBackupError.invalidFile
        }
        return preferences
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum UserDataBackupError: LocalizedError, Equatable {
    case invalidFile
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "This is not a valid Vela backup."
        case let .unsupportedVersion(version):
            "This backup uses unsupported format version \(version). Update Vela and try again."
        }
    }
}
