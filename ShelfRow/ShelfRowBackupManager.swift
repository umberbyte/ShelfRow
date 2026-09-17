//
//  ShelfRowBackupManager.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/17.
//

import Foundation

struct ShelfRowBackupSummary: Equatable, Sendable {
    var copiedFiles = 0
    var skippedFiles = 0
    var removedFiles = 0

    nonisolated init(copiedFiles: Int = 0, skippedFiles: Int = 0, removedFiles: Int = 0) {
        self.copiedFiles = copiedFiles
        self.skippedFiles = skippedFiles
        self.removedFiles = removedFiles
    }
}

enum ShelfRowBackupManager {
    private struct BackupSource: Sendable {
        let name: String
        let url: URL
        let isDirectory: Bool
    }

    private struct ManifestEntry: Codable, Sendable {
        var size: Int64
        var modificationTime: TimeInterval

        nonisolated init(size: Int64, modificationTime: TimeInterval) {
            self.size = size
            self.modificationTime = modificationTime
        }

        nonisolated func matches(_ other: ManifestEntry) -> Bool {
            size == other.size && modificationTime == other.modificationTime
        }
    }

    nonisolated static func backUp(to selectedFolder: URL) throws -> ShelfRowBackupSummary {
        UserDefaults.standard.synchronize()

        let backupRoot = selectedFolder.appendingPathComponent("ShelfRowBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let manifestURL = backupRoot.appendingPathComponent("manifest.json")
        let previousManifest = readManifest(from: manifestURL)
        let sources = backupSources()

        var currentManifest: [String: ManifestEntry] = [:]
        var summary = ShelfRowBackupSummary()

        for source in sources {
            // Continue to the next source even if one fails, such as a permission error on a single source.
            try? backUpSource(
                source,
                backupRoot: backupRoot,
                previousManifest: previousManifest,
                currentManifest: &currentManifest,
                summary: &summary
            )
        }

        for relativePath in previousManifest.keys where currentManifest[relativePath] == nil {
            let staleURL = backupRoot.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: staleURL.path) {
                try FileManager.default.removeItem(at: staleURL)
                summary.removedFiles += 1
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(currentManifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        return summary
    }

    nonisolated static func restore(from selectedFolder: URL) throws -> ShelfRowBackupSummary {
        let backupRoot = selectedFolder.appendingPathComponent("ShelfRowBackup", isDirectory: true)
        let manifestURL = backupRoot.appendingPathComponent("manifest.json")
        let manifest = readManifest(from: manifestURL)
        guard !manifest.isEmpty else {
            throw NSError(
                domain: "ShelfRowBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "バックアップのmanifest.jsonが見つからないか、空です。"]
            )
        }

        let sources = Dictionary(uniqueKeysWithValues: backupSources().map { ($0.name, $0) })
        var summary = ShelfRowBackupSummary()

        try removeFilesMissingFromBackup(
            backupManifest: manifest,
            sources: sources,
            backupRoot: backupRoot,
            summary: &summary
        )

        for relativePath in manifest.keys.sorted() {
            guard let splitPath = splitBackupRelativePath(relativePath),
                  let source = sources[splitPath.sourceName] else {
                continue
            }

            let backupFileURL = backupRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: backupFileURL.path) else {
                continue
            }

            let destinationURL = source.isDirectory
                ? source.url.appendingPathComponent(splitPath.pathInsideSource)
                : source.url
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: backupFileURL, to: destinationURL)
            if let entry = manifest[relativePath] {
                let modificationDate = Date(timeIntervalSince1970: entry.modificationTime)
                try? FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destinationURL.path)
            }
            summary.copiedFiles += 1
        }

        UserDefaults.standard.synchronize()
        return summary
    }

    nonisolated private static func backupSources() -> [BackupSource] {
        let fileManager = FileManager.default
        var sources: [BackupSource] = []

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           fileManager.fileExists(atPath: applicationSupport.path) {
            sources.append(BackupSource(name: "ApplicationSupport", url: applicationSupport, isDirectory: true))
        }

        let thumbnailDir = ThumbnailCache.diskCacheDirectory
        if fileManager.fileExists(atPath: thumbnailDir.path) {
            sources.append(BackupSource(name: "Thumbnails", url: thumbnailDir, isDirectory: true))
        }

        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let bundleID = Bundle.main.bundleIdentifier ?? "jp.aromatics.ShelfRow"
            let preferences = library
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(bundleID).plist")
            if fileManager.fileExists(atPath: preferences.path) {
                sources.append(BackupSource(name: "Preferences", url: preferences, isDirectory: false))
            }
        }

        return sources
    }

    nonisolated private static func removeFilesMissingFromBackup(
        backupManifest: [String: ManifestEntry],
        sources: [String: BackupSource],
        backupRoot: URL,
        summary: inout ShelfRowBackupSummary
    ) throws {
        for source in sources.values {
            if source.isDirectory {
                guard let enumerator = FileManager.default.enumerator(
                    at: source.url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsPackageDescendants]
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator {
                    if isFile(fileURL, containedIn: backupRoot) {
                        continue
                    }
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { continue }
                    let relative = source.name + "/" + relativePath(from: source.url, to: fileURL)
                    if backupManifest[relative] == nil {
                        try FileManager.default.removeItem(at: fileURL)
                        summary.removedFiles += 1
                    }
                }
            } else {
                let relative = source.name + "/" + source.url.lastPathComponent
                if backupManifest[relative] == nil, FileManager.default.fileExists(atPath: source.url.path) {
                    try FileManager.default.removeItem(at: source.url)
                    summary.removedFiles += 1
                }
            }
        }
    }

    nonisolated private static func isSQLiteAuxiliaryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal")
    }

    nonisolated private static func backUpSource(
        _ source: BackupSource,
        backupRoot: URL,
        previousManifest: [String: ManifestEntry],
        currentManifest: inout [String: ManifestEntry],
        summary: inout ShelfRowBackupSummary
    ) throws {
        if source.isDirectory {
            guard let enumerator = FileManager.default.enumerator(
                at: source.url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants]
            ) else {
                return
            }

            for case let fileURL as URL in enumerator {
                if isFile(fileURL, containedIn: backupRoot) {
                    continue
                }
                // SQLite WAL/SHM/journal files are ephemeral transaction logs; skip them.
                if isSQLiteAuxiliaryFile(fileURL) {
                    continue
                }
                do {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true else { continue }
                    let relativePath = source.name + "/" + relativePath(from: source.url, to: fileURL)
                    try backUpFile(
                        from: fileURL,
                        relativePath: relativePath,
                        values: values,
                        backupRoot: backupRoot,
                        previousManifest: previousManifest,
                        currentManifest: &currentManifest,
                        summary: &summary
                    )
                } catch {
                    // Skip files that cannot be read or copied, and continue to the next file.
                    summary.skippedFiles += 1
                }
            }
        } else {
            let values = try source.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { return }
            let relativePath = source.name + "/" + source.url.lastPathComponent
            try backUpFile(
                from: source.url,
                relativePath: relativePath,
                values: values,
                backupRoot: backupRoot,
                previousManifest: previousManifest,
                currentManifest: &currentManifest,
                summary: &summary
            )
        }
    }

    nonisolated private static func backUpFile(
        from sourceURL: URL,
        relativePath: String,
        values: URLResourceValues,
        backupRoot: URL,
        previousManifest: [String: ManifestEntry],
        currentManifest: inout [String: ManifestEntry],
        summary: inout ShelfRowBackupSummary
    ) throws {
        let entry = ManifestEntry(
            size: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
        currentManifest[relativePath] = entry

        let destinationURL = backupRoot.appendingPathComponent(relativePath)
        if previousManifest[relativePath]?.matches(entry) == true,
           FileManager.default.fileExists(atPath: destinationURL.path) {
            summary.skippedFiles += 1
            return
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        if let modificationDate = values.contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destinationURL.path)
        }
        summary.copiedFiles += 1
    }

    nonisolated private static func relativePath(from root: URL, to fileURL: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
        let startIndex = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        return String(filePath[startIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    nonisolated private static func splitBackupRelativePath(_ relativePath: String) -> (sourceName: String, pathInsideSource: String)? {
        guard let slashIndex = relativePath.firstIndex(of: "/") else { return nil }
        let sourceName = String(relativePath[..<slashIndex])
        let pathStart = relativePath.index(after: slashIndex)
        let pathInsideSource = String(relativePath[pathStart...])
        guard !sourceName.isEmpty, !pathInsideSource.isEmpty else { return nil }
        return (sourceName, pathInsideSource)
    }

    nonisolated private static func readManifest(from url: URL) -> [String: ManifestEntry] {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: ManifestEntry].self, from: data) else {
            return [:]
        }
        return manifest
    }
}
