import Foundation
import OSLog
import SwiftData

struct DuplicateRecordSummary: Sendable, Equatable {
    let groupCount: Int
    let duplicateCount: Int

    nonisolated static let empty = DuplicateRecordSummary(groupCount: 0, duplicateCount: 0)
}

/// Conservatively repairs duplicate `Item` rows created by a sync mistake.
///
/// Stackroom IDs are authoritative. Items without one are merged only when
/// their volume and relative file paths are the same. Two different non-nil
/// Stackroom IDs are never collapsed merely because they point at one archive:
/// the importer intentionally permits that arrangement.
@ModelActor
actor DuplicateRecordResolver {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "DuplicateRepair")

    private enum Identity: Hashable {
        case legacy(Int)
        case file(volume: String, relativePath: String)
    }

    func preview() throws -> DuplicateRecordSummary {
        let groups = try duplicateGroups()
        return summary(for: groups)
    }

    func resolve() async throws -> DuplicateRecordSummary {
        let groups = try duplicateGroups()
        guard !groups.isEmpty else { return .empty }
        Self.logger.info("Preparing to merge \(groups.count, privacy: .public) duplicate group(s)")

        var extractionRecordsByItemID = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<CoverExtractionRecord>()),
            by: \.itemID
        )
        var bookmarksByTargetID = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<LocalBookmark>()),
            by: \.targetID
        )
        var coverStatesByItemID = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<LocalCoverState>()),
            by: \.itemID
        )
        Self.logger.info("Indexed auxiliary records for duplicate repair")

        for (groupIndex, group) in groups.enumerated() {
            let ordered = group.sorted { $0.id.uuidString < $1.id.uuidString }
            guard let survivor = ordered.first else { continue }
            let duplicates = Array(ordered.dropFirst())
            let duplicateIDs = Set(duplicates.map(\.id))
            let allIDs = duplicateIDs.union([survivor.id])

            mergeMetadata(from: duplicates, into: survivor)
            mergeShelfMembership(from: duplicates, into: survivor)
            let extractionRecords = takeRecords(for: allIDs, from: &extractionRecordsByItemID)
            let bookmarks = takeRecords(for: allIDs, from: &bookmarksByTargetID)
            let coverStates = takeRecords(for: allIDs, from: &coverStatesByItemID)
            mergeExtractionRecords(extractionRecords, into: survivor.id)
            mergeBookmarks(bookmarks, into: survivor.id)
            mergeCoverStates(coverStates, into: survivor.id)
            reconcileThumbnailFiles(survivorID: survivor.id, duplicateIDs: duplicateIDs)

            for duplicate in duplicates {
                modelContext.delete(duplicate)
            }

            if groupIndex.isMultiple(of: 250) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }

        let result = summary(for: groups)
        Self.logger.info("Saving \(result.duplicateCount, privacy: .public) merged duplicate record(s)")
        try modelContext.save()
        Self.logger.info("Merged \(result.duplicateCount, privacy: .public) duplicate record(s) in \(result.groupCount, privacy: .public) group(s)")
        return result
    }

    private func duplicateGroups() throws -> [[Item]] {
        let items = try modelContext.fetch(FetchDescriptor<Item>())
        var grouped: [Identity: [Item]] = [:]
        grouped.reserveCapacity(items.count)

        for item in items {
            guard let identity = identity(for: item) else { continue }
            grouped[identity, default: []].append(item)
        }

        return grouped.values
            .filter { $0.count > 1 }
            .sorted { first, second in
                let firstID = first.map(\.id.uuidString).min() ?? ""
                let secondID = second.map(\.id.uuidString).min() ?? ""
                return firstID < secondID
            }
    }

    private func identity(for item: Item) -> Identity? {
        if let legacyID = item.legacyID {
            return .legacy(legacyID)
        }

        guard let volume = item.volume else { return nil }
        let relativePath = normalizedPath(item.relativePath)
        guard !relativePath.isEmpty else { return nil }
        let storedVolumePath = normalizedPath(volume.lastKnownPath)
        let volumeIdentity = storedVolumePath.isEmpty
            ? "id:\(volume.id.uuidString)"
            : "path:\(storedVolumePath)"
        return .file(volume: volumeIdentity, relativePath: relativePath)
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed.precomposedStringWithCanonicalMapping as NSString).standardizingPath
    }

    private func summary(for groups: [[Item]]) -> DuplicateRecordSummary {
        DuplicateRecordSummary(
            groupCount: groups.count,
            duplicateCount: groups.reduce(0) { $0 + max(0, $1.count - 1) }
        )
    }

    /// Removes and returns only the records belonging to one duplicate group.
    /// Building the dictionaries once keeps a library-sized repair linear; a
    /// per-group scan of every auxiliary row becomes quadratic when a sync
    /// mistake duplicates most of the library.
    private func takeRecords<Record>(
        for itemIDs: Set<UUID>,
        from recordsByItemID: inout [UUID: [Record]]
    ) -> [Record] {
        itemIDs.flatMap { recordsByItemID.removeValue(forKey: $0) ?? [] }
    }

    private func mergeMetadata(from duplicates: [Item], into survivor: Item) {
        for duplicate in duplicates {
            if survivor.legacyID == nil { survivor.legacyID = duplicate.legacyID }
            if survivor.volume == nil { survivor.volume = duplicate.volume }
            fill(&survivor.relativePath, from: duplicate.relativePath)
            if survivor.bookmarkData == nil { survivor.bookmarkData = duplicate.bookmarkData }
            fill(&survivor.title, from: duplicate.title)
            fill(&survivor.author, from: duplicate.author)
            fill(&survivor.genre, from: duplicate.genre)
            fill(&survivor.relation, from: duplicate.relation)
            fill(&survivor.keywordA, from: duplicate.keywordA)
            fill(&survivor.keywordB, from: duplicate.keywordB)
            fill(&survivor.memo, from: duplicate.memo)
            fill(&survivor.coverImageName, from: duplicate.coverImageName)
            fill(&survivor.coverImagePath, from: duplicate.coverImagePath)

            survivor.rating = max(survivor.rating, duplicate.rating)
            survivor.isUnread = survivor.isUnread && duplicate.isUnread
            survivor.addedDate = min(survivor.addedDate, duplicate.addedDate)
            survivor.lastReadDate = latest(survivor.lastReadDate, duplicate.lastReadDate)
            survivor.pages = max(survivor.pages, duplicate.pages)

            if duplicate.coverVersion > survivor.coverVersion {
                survivor.coverVersion = duplicate.coverVersion
                survivor.coverBytes = duplicate.coverBytes
            } else if duplicate.coverVersion == survivor.coverVersion {
                survivor.coverBytes = max(survivor.coverBytes, duplicate.coverBytes)
            }
        }
    }

    private func fill(_ value: inout String, from candidate: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = candidate
        }
    }

    private func latest(_ first: Date?, _ second: Date?) -> Date? {
        switch (first, second) {
        case let (first?, second?): return max(first, second)
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }

    private func mergeShelfMembership(from duplicates: [Item], into survivor: Item) {
        var shelves = survivor.shelves ?? []
        var shelfIDs = Set(shelves.map(\.id))
        for duplicate in duplicates {
            for shelf in duplicate.shelves ?? [] where shelfIDs.insert(shelf.id).inserted {
                shelves.append(shelf)
            }
        }
        survivor.shelves = shelves
    }

    private func mergeExtractionRecords(
        _ records: [CoverExtractionRecord],
        into survivorID: UUID
    ) {
        guard let newest = records.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        let keeper = records.first(where: { $0.itemID == survivorID }) ?? newest
        keeper.itemID = survivorID
        keeper.outcomeRaw = newest.outcomeRaw
        keeper.updatedAt = newest.updatedAt
        for record in records where record !== keeper {
            modelContext.delete(record)
        }
    }

    private func mergeBookmarks(
        _ bookmarks: [LocalBookmark],
        into survivorID: UUID
    ) {
        guard let newest = bookmarks.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        let best = bookmarks
            .filter { !$0.data.isEmpty }
            .max(by: { $0.updatedAt < $1.updatedAt }) ?? newest
        let keeper = bookmarks.first(where: { $0.targetID == survivorID }) ?? best
        keeper.data = best.data
        keeper.updatedAt = best.updatedAt
        keeper.targetID = survivorID
        for bookmark in bookmarks where bookmark !== keeper {
            modelContext.delete(bookmark)
        }
    }

    private func mergeCoverStates(
        _ states: [LocalCoverState],
        into survivorID: UUID
    ) {
        guard let best = states.max(by: {
            ($0.version, $0.bytes, $0.updatedAt) < ($1.version, $1.bytes, $1.updatedAt)
        }) else { return }
        let keeper = states.first(where: { $0.itemID == survivorID }) ?? best
        keeper.itemID = survivorID
        keeper.version = best.version
        keeper.bytes = best.bytes
        keeper.pendingUpload = states.contains(where: \.pendingUpload)
        keeper.attempts = states.map(\.attempts).max() ?? 0
        keeper.lastErrorCode = best.lastErrorCode
        keeper.updatedAt = states.map(\.updatedAt).max() ?? best.updatedAt
        for state in states where state !== keeper {
            modelContext.delete(state)
        }
    }

    private func reconcileThumbnailFiles(survivorID: UUID, duplicateIDs: Set<UUID>) {
        let fileManager = FileManager.default
        let directory = ThumbnailCache.diskCacheDirectory
        let survivorURL = directory.appendingPathComponent("\(survivorID.uuidString).jpg")

        if !fileManager.fileExists(atPath: survivorURL.path) {
            let candidates = duplicateIDs
                .map { directory.appendingPathComponent("\($0.uuidString).jpg") }
                .filter { fileManager.fileExists(atPath: $0.path) }
                .sorted { fileSize($0) > fileSize($1) }
            if let source = candidates.first {
                do {
                    try fileManager.copyItem(at: source, to: survivorURL)
                } catch {
                    Self.logger.error("Could not preserve a duplicate thumbnail: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        for duplicateID in duplicateIDs {
            let duplicateURL = directory.appendingPathComponent("\(duplicateID.uuidString).jpg")
            guard fileManager.fileExists(atPath: duplicateURL.path) else { continue }
            do {
                try fileManager.removeItem(at: duplicateURL)
            } catch {
                Self.logger.error("Could not remove a duplicate thumbnail: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
