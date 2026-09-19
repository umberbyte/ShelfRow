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

    // MARK: - The index of what the folder holds

    static let manifestName = ".shelfrow-thumbnails-index.json"

    /// What the distribution folder holds, as one file.
    ///
    /// The alternative was to raise every book's `coverVersion` when covers were
    /// registered, so the other devices would learn of them through iCloud. That
    /// works, but it means a library-sized registration pushes 19,287 record
    /// changes up and every other device pulls them down — minutes of CPU on each
    /// machine to carry information this file states in about a megabyte.
    ///
    /// So the folder describes itself. `Item.coverVersion` keeps its own meaning
    /// and iCloud is left out of it: covers are not iCloud's business, and now
    /// neither is the bookkeeping about them.
    struct Manifest: Codable, Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable {
            /// Raised each time this book's cover is written again, so a device
            /// holding an older one can tell.
            var version: Int
            var bytes: Int
        }

        var formatVersion: Int = ThumbnailDistribution.formatVersion
        var updatedAt: Date = Date()
        var updatedBy: String = Host.current().localizedName ?? "Mac"
        /// Keyed by the item's UUID string — the same name the file carries.
        var entries: [String: Entry] = [:]

        func entry(for itemID: UUID) -> Entry? { entries[itemID.uuidString] }

        var itemIDs: Set<UUID> {
            Set(entries.keys.compactMap(UUID.init(uuidString:)))
        }
    }

    static func manifestURL(in root: URL) -> URL {
        root.appendingPathComponent(manifestName, isDirectory: false)
    }

    /// Reads the index, or an empty one when the folder has never had covers put
    /// in it. A folder with files but no index is not a case worth handling
    /// specially: the next registration writes one.
    static func readManifest(in root: URL) -> Manifest {
        let url = manifestURL(in: root)
        guard let data = try? Data(contentsOf: url) else { return Manifest(entries: [:]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
            logger.error("The distribution index could not be read; treating the folder as empty")
            return Manifest(entries: [:])
        }
        return manifest
    }

    /// Merges entries into the index and writes it back.
    ///
    /// Read-modify-write, which is enough for one person moving between their own
    /// Macs. Two devices registering at the same moment could lose one side's
    /// entries; the next pass on that device notices its covers are not in the
    /// index and puts them back.
    static func updateManifest(in root: URL, merging entries: [String: Manifest.Entry]) throws -> Manifest {
        var manifest = readManifest(in: root)
        manifest.entries.merge(entries) { _, new in new }
        manifest.updatedAt = Date()
        manifest.updatedBy = Host.current().localizedName ?? "Mac"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: root), options: .atomic)
        logger.info("The distribution folder now lists \(manifest.entries.count, privacy: .public) covers")
        return manifest
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
    /// Which covers the folder holds, from the index. Cover generation checks this
    /// before reaching for the share: asking a share about a file that is not
    /// there costs the same round trip as fetching one that is, and a bulk run
    /// would ask twenty thousand times.
    nonisolated(unsafe) private static var published: Set<UUID> = []

    static var currentRoot: URL? {
        get {
            rootLock.lock()
            defer { rootLock.unlock() }
            return openRoot
        }
        set {
            rootLock.lock()
            openRoot = newValue
            if newValue == nil { published = [] }
            rootLock.unlock()
            forgetShards()
        }
    }

    /// Whether the folder is known to hold this book's cover.
    static func holdsCover(forItemID itemID: UUID) -> Bool {
        rootLock.lock()
        defer { rootLock.unlock() }
        return openRoot != nil && published.contains(itemID)
    }

    static func setPublishedCovers(_ ids: Set<UUID>) {
        rootLock.lock()
        published = ids
        rootLock.unlock()
    }

    // MARK: - Paths

    /// Where a thumbnail lives inside the root.
    ///
    /// Sharded on the first two characters of the identifier: twenty thousand
    /// files in one directory is slow to create into and slower to list over SMB,
    /// and 256 buckets brings it to about seventy-five files each.
    ///
    /// The shard is lower-cased. A share this was tried against lower-cases the
    /// names of directories as it creates them, while resolving paths
    /// case-sensitively — so asking for "0A" was answered first with "that
    /// already exists" and then with "there is no such directory", and every
    /// cover whose identifier began with a hex letter failed. Naming the shard
    /// the way such a server will store it makes both answers agree, and costs
    /// nothing anywhere else. The file keeps the identifier's own spelling, which
    /// servers do preserve.
    static func fileURL(forItemID itemID: UUID, in root: URL) -> URL {
        let name = itemID.uuidString
        return root
            .appendingPathComponent(String(name.prefix(2)).lowercased(), isDirectory: true)
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
        try ensureShardExists(destination.deletingLastPathComponent())

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(itemID.uuidString).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: localFile, to: temporary)

        do {
            // A plain rename, not `replaceItemAt`. The latter keeps the old file
            // aside, moves metadata across and asks the volume a good deal on the
            // way — over a share, all of it round trips, and none of it is wanted
            // here: the file being replaced is an older copy of this same cover.
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Creating a directory that is already there still costs a round trip over a
    /// share, and a library-sized run would pay it once per file for 256 folders
    /// that stop being new almost immediately.
    private static let shardLock = NSLock()
    nonisolated(unsafe) private static var knownShards: Set<String> = []

    private static func ensureShardExists(_ shard: URL) throws {
        shardLock.lock()
        let known = knownShards.contains(shard.path)
        shardLock.unlock()
        guard !known else { return }

        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        shardLock.lock()
        knownShards.insert(shard.path)
        shardLock.unlock()
    }

    /// Forgets which folders are known to exist, for when the root changes.
    static func forgetShards() {
        shardLock.lock()
        knownShards.removeAll()
        shardLock.unlock()
    }

    /// Copies a thumbnail out of the distribution folder into the local cache,
    /// and answers its size. The same rename dance, for the same reason.
    @discardableResult
    static func download(forItemID itemID: UUID, from root: URL, to localFile: URL) throws -> Int {
        let source = fileURL(forItemID: itemID, in: root)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        // One atomic write, which is itself a write to a temporary name in the
        // same directory followed by a rename. Doing that and then replacing the
        // file with it again was the same dance twice.
        let data = try Data(contentsOf: source)
        try data.write(to: localFile, options: .atomic)
        return data.count
    }
}
