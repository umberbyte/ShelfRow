//
//  ThumbnailDistribution.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// The folder on the NAS that thumbnails are handed around through, and the
/// rules for recognising it.
///
/// Covers are copyrighted artwork and around a gigabyte all told, so they do not
/// go to iCloud. They do not need to: the books themselves already live on a
/// share every device can reach, and a folder beside them costs nothing. The one
/// device that generated a thumbnail writes it there; every other device copies
/// it instead of opening the archive again.
///
/// A file here is named exactly as the local cache names it, so the folder is a
/// plain copy of the cache rather than a format of its own — nothing to convert
/// and no table mapping one name to the other.
enum ThumbnailDistribution {
    static let folderName = "ShelfRowThumbnails"
    static let markerName = ".shelfrow-thumbnails.json"
    static let formatVersion = 1

    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "ThumbnailDistribution")

    /// Written when a folder is made a distribution root, and read to tell one
    /// from an unrelated folder.
    struct Marker: Codable, Sendable, Equatable {
        var formatVersion: Int
        var libraryID: UUID
        var createdAt: Date
        var createdBy: String
    }

    /// Why a folder cannot be used.
    enum RootProblem: Error, Equatable, Sendable {
        case unreachable
        case notADistributionFolder
        case unsupportedFormat(Int)
        case differentLibrary
        case unreadableMarker(String)

        var message: String {
            switch self {
            case .unreachable:
                return "配布元フォルダに到達できません。"
            case .notADistributionFolder:
                return "このフォルダは配布元として初期化されていません。"
            case .unsupportedFormat(let version):
                return "配布元の形式（バージョン \(version)）に対応していません。アプリを更新してください。"
            case .differentLibrary:
                return "別のライブラリの配布元です。このフォルダは使用できません。"
            case .unreadableMarker(let reason):
                return "配布元の情報を読めません: \(reason)"
            }
        }
    }

    // MARK: - The folder in use

    /// The root currently open, for the one caller that cannot reach the
    /// coordinator: cover generation runs off the main actor, and before it opens
    /// an archive it should ask whether another Mac has already done the work.
    ///
    /// Access is kept behind a lock rather than an actor because the read happens
    /// on every cover that misses the cache, and waiting on an actor hop there
    /// would show up as a stutter while scrolling.
    private static let rootLock = NSLock()
    nonisolated(unsafe) private static var openRoot: URL?

    static var currentRoot: URL? {
        get {
            rootLock.lock()
            defer { rootLock.unlock() }
            return openRoot
        }
        set {
            rootLock.lock()
            openRoot = newValue
            rootLock.unlock()
        }
    }

    // MARK: - Paths

    /// Where a thumbnail lives inside the root.
    ///
    /// Sharded on the first two characters of the identifier: twenty thousand
    /// files in one directory is slow to create into and slower to list over SMB,
    /// and 256 buckets brings it to about seventy-five files each.
    static func fileURL(forItemID itemID: UUID, in root: URL) -> URL {
        let name = itemID.uuidString
        return root
            .appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(name).jpg", isDirectory: false)
    }

    static func markerURL(in root: URL) -> URL {
        root.appendingPathComponent(markerName, isDirectory: false)
    }

    /// The folder to offer when nobody has chosen one: beside the books.
    static func suggestedRoot(forVolumePath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Library identity

    /// The identifier shared by every device working on one library.
    ///
    /// Kept in iCloud's key-value store, which this app is already entitled to
    /// use, because one string does not justify a mechanism of its own. Its
    /// purpose is to catch the folder chosen by mistake: pointing a device at
    /// another library's distribution root, or at an unrelated folder, would
    /// otherwise fill it with twenty thousand files that do not belong there.
    private static let libraryIDKey = "thumbnailLibraryID"

    static var sharedLibraryID: UUID? {
        guard let stored = NSUbiquitousKeyValueStore.default.string(forKey: libraryIDKey) else { return nil }
        return UUID(uuidString: stored)
    }

    /// Records the identifier for the other devices to check against. Called when
    /// a root is initialised.
    static func publishLibraryID(_ id: UUID) {
        let store = NSUbiquitousKeyValueStore.default
        store.set(id.uuidString, forKey: libraryIDKey)
        store.synchronize()
        logger.info("Published the library identifier for thumbnail distribution")
    }

    // MARK: - Reading and writing the marker

    static func readMarker(in root: URL) -> Result<Marker, RootProblem> {
        let url = markerURL(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A folder that is not there and a folder that is empty need
            // different answers: the first will come back when the share mounts.
            return .failure(FileManager.default.fileExists(atPath: root.path)
                ? .notADistributionFolder
                : .unreachable)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let marker = try decoder.decode(Marker.self, from: try Data(contentsOf: url))
            guard marker.formatVersion <= formatVersion else {
                return .failure(.unsupportedFormat(marker.formatVersion))
            }
            return .success(marker)
        } catch {
            return .failure(.unreadableMarker(error.localizedDescription))
        }
    }

    /// Makes a folder a distribution root, and publishes its identity.
    ///
    /// Reuses the library identifier other devices already agreed on when there is
    /// one, so a root rebuilt after a mishap is still the same library's.
    static func initialiseRoot(at root: URL) throws -> Marker {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let marker = Marker(
            formatVersion: formatVersion,
            libraryID: sharedLibraryID ?? UUID(),
            createdAt: Date(),
            createdBy: Host.current().localizedName ?? "Mac"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL(in: root), options: .atomic)

        publishLibraryID(marker.libraryID)
        logger.info("Initialised a thumbnail distribution folder")
        return marker
    }

    /// Whether this folder is a root this device may use.
    static func validate(root: URL) -> Result<Marker, RootProblem> {
        switch readMarker(in: root) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let marker):
            // No shared identifier yet means this device is the first to look;
            // adopting the folder's is what makes the two agree.
            guard let shared = sharedLibraryID else {
                publishLibraryID(marker.libraryID)
                return .success(marker)
            }
            return shared == marker.libraryID ? .success(marker) : .failure(.differentLibrary)
        }
    }

    // MARK: - Moving one file

    /// Copies a thumbnail into the distribution folder.
    ///
    /// Through a temporary name in the destination directory and a rename, so a
    /// reader never opens a half-written file: a rename within one directory is
    /// close enough to atomic on SMB, while writing in place is not.
    static func upload(from localFile: URL, forItemID itemID: UUID, to root: URL) throws {
        let destination = fileURL(forItemID: itemID, in: root)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(itemID.uuidString).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: localFile, to: temporary)

        do {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Copies a thumbnail out of the distribution folder into the local cache,
    /// and answers its size. The same rename dance, for the same reason.
    @discardableResult
    static func download(forItemID itemID: UUID, from root: URL, to localFile: URL) throws -> Int {
        let source = fileURL(forItemID: itemID, in: root)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        let data = try Data(contentsOf: source)
        let temporary = localFile.deletingLastPathComponent()
            .appendingPathComponent(".\(itemID.uuidString).tmp")
        try data.write(to: temporary, options: .atomic)

        do {
            _ = try fileManager.replaceItemAt(localFile, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return data.count
    }
}
