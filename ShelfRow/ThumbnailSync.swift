//
//  ThumbnailSync.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// What this device has to send or fetch, and what it has already.
struct CoverDistributionCounts: Sendable, Equatable {
    /// Thumbnails this device holds at the version the library asks for.
    var held: Int = 0
    /// Thumbnails to fetch from the distribution folder.
    var missing: Int = 0
    /// Thumbnails this device generated that the folder does not have yet.
    var toUpload: Int = 0
    /// Given up on for now — three tries at the same version (§21.9).
    var failed: Int = 0
}

/// One thumbnail to fetch.
struct CoverFetchTarget: Sendable, Equatable {
    let itemID: UUID
    /// The version the library says is current; recorded once the file is here.
    let version: Int
    /// What the file should weigh, for the only check worth making.
    let expectedBytes: Int
}

/// One thumbnail to hand to the distribution folder.
struct CoverUploadTarget: Sendable, Equatable {
    let itemID: UUID
    /// The version to record once the folder has it.
    let version: Int
}

/// The result of moving one file, on the way back to the store.
struct CoverFetchResult: Sendable {
    let itemID: UUID
    let version: Int
    let bytes: Int
    let errorCode: Int?
}

/// Reads and writes the thumbnail bookkeeping off the main actor.
///
/// Both stores hang off the one container, so the library's `Item` rows and the
/// device-local `LocalCoverState` rows can be compared in a single context —
/// which is the whole of the difference calculation (§21.5).
@ModelActor
actor CoverDistributionStore {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "ThumbnailDistribution")

    /// Where this device stops asking for a version that will not come.
    static let maxAttempts = 3

    private func statesByItemID() throws -> [UUID: LocalCoverState] {
        Dictionary(
            try modelContext.fetch(FetchDescriptor<LocalCoverState>()).map { ($0.itemID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func cacheFileURL(_ itemID: UUID) -> URL {
        ThumbnailCache.diskCacheDirectory.appendingPathComponent("\(itemID.uuidString).jpg")
    }

    /// Every thumbnail on disk and its size, from one directory listing.
    ///
    /// Asking the file system about each book in turn is twenty thousand system
    /// calls for an answer one enumeration already holds. On a library this size
    /// that difference is the difference between a pause and a freeze.
    private static func cacheInventory() -> [UUID: Int] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: ThumbnailCache.diskCacheDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var inventory: [UUID: Int] = [:]
        inventory.reserveCapacity(files.count)
        for file in files where file.pathExtension == "jpg" {
            guard let itemID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            inventory[itemID] = (try? file.resourceValues(forKeys: Set(keys)))?.fileSize ?? 0
        }
        return inventory
    }

    /// The parts of a book this bookkeeping needs, without materialising the rest
    /// of it. A library-sized fetch of whole records is most of the cost here.
    private struct CoverFacts {
        let id: UUID
        let coverVersion: Int
        let coverBytes: Int
    }

    private func coverFacts() throws -> [CoverFacts] {
        var descriptor = FetchDescriptor<Item>()
        descriptor.propertiesToFetch = [\.id, \.coverVersion, \.coverBytes]
        return try modelContext.fetch(descriptor).map {
            CoverFacts(id: $0.id, coverVersion: $0.coverVersion, coverBytes: $0.coverBytes)
        }
    }

    /// The books whose thumbnail this device should fetch.
    func fetchTargets() throws -> [CoverFetchTarget] {
        let states = try statesByItemID()
        let inventory = Self.cacheInventory()

        return try coverFacts().compactMap { book in
            guard book.coverVersion > 0 else { return nil }
            let state = states[book.id]

            // A version this device has already tried three times is left alone
            // until the library moves on to a new one.
            if let state, state.attempts >= Self.maxAttempts, state.version < book.coverVersion,
               state.lastErrorCode != 0 {
                return nil
            }

            let hasCurrentVersion = state?.version == book.coverVersion
            guard !hasCurrentVersion || inventory[book.id] == nil else { return nil }

            return CoverFetchTarget(itemID: book.id, version: book.coverVersion, expectedBytes: book.coverBytes)
        }
    }

    /// The thumbnails this device has that the distribution folder does not.
    ///
    /// Two cases, one rule: a cover generated before distribution existed
    /// (`coverVersion == 0`), and one generated while the NAS was out of reach.
    func uploadTargets() throws -> [CoverUploadTarget] {
        let states = try statesByItemID()
        let inventory = Self.cacheInventory()

        return try coverFacts().compactMap { book in
            guard inventory[book.id] != nil else { return nil }
            let state = states[book.id]

            if book.coverVersion == 0 {
                return CoverUploadTarget(itemID: book.id, version: 1)
            }
            if state?.pendingUpload == true {
                return CoverUploadTarget(itemID: book.id, version: book.coverVersion)
            }
            return nil
        }
    }

    func counts() throws -> CoverDistributionCounts {
        let states = try statesByItemID()
        let inventory = Self.cacheInventory()
        var counts = CoverDistributionCounts()

        for book in try coverFacts() {
            let state = states[book.id]
            let hasFile = inventory[book.id] != nil

            if book.coverVersion == 0 {
                if hasFile { counts.toUpload += 1 }
                continue
            }
            if state?.pendingUpload == true { counts.toUpload += 1 }

            if state?.version == book.coverVersion, hasFile {
                counts.held += 1
            } else if let state, state.attempts >= Self.maxAttempts, state.lastErrorCode != 0 {
                counts.failed += 1
            } else {
                counts.missing += 1
            }
        }
        return counts
    }

    /// How many rows are written before a save. A library-sized run held in one
    /// transaction is a long stall at the end and a lot of memory until then.
    private static let writeChunk = 500

    /// Records what came of fetching a batch.
    func recordFetched(_ results: [CoverFetchResult]) {
        guard !results.isEmpty else { return }
        do {
            let states = try statesByItemID()
            var sinceSave = 0
            for result in results {
                let state = states[result.itemID] ?? {
                    let fresh = LocalCoverState(itemID: result.itemID)
                    modelContext.insert(fresh)
                    return fresh
                }()

                if let errorCode = result.errorCode {
                    state.attempts += 1
                    state.lastErrorCode = errorCode
                } else {
                    state.version = result.version
                    state.bytes = result.bytes
                    state.attempts = 0
                    state.lastErrorCode = 0
                }
                state.updatedAt = Date()

                sinceSave += 1
                if sinceSave >= Self.writeChunk {
                    try modelContext.save()
                    sinceSave = 0
                }
            }
            try modelContext.save()
        } catch {
            Self.logger.error("Could not record fetched thumbnails: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records that the distribution folder now has these, and moves the library's
    /// version along so every other device learns of them through iCloud.
    func recordUploaded(_ uploaded: [CoverFetchResult]) {
        guard !uploaded.isEmpty else { return }
        do {
            let states = try statesByItemID()
            // Whole records this time: their version is what has to change, and
            // that is the number every other device reads to know there is
            // something to fetch.
            let items = Dictionary(
                try modelContext.fetch(FetchDescriptor<Item>()).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var sinceSave = 0

            for result in uploaded {
                let state = states[result.itemID] ?? {
                    let fresh = LocalCoverState(itemID: result.itemID)
                    modelContext.insert(fresh)
                    return fresh
                }()

                guard result.errorCode == nil else {
                    // Left pending: the folder is the thing that was missing, and
                    // it will be reachable again.
                    state.pendingUpload = true
                    state.lastErrorCode = result.errorCode ?? 0
                    state.updatedAt = Date()
                    continue
                }

                if let item = items[result.itemID] {
                    item.coverVersion = result.version
                    item.coverBytes = result.bytes
                }
                state.version = result.version
                state.bytes = result.bytes
                state.pendingUpload = false
                state.attempts = 0
                state.lastErrorCode = 0
                state.updatedAt = Date()

                sinceSave += 1
                if sinceSave >= Self.writeChunk {
                    try modelContext.save()
                    sinceSave = 0
                }
            }
            try modelContext.save()
        } catch {
            Self.logger.error("Could not record uploaded thumbnails: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records the files already sitting in the cache at the version the library
    /// asks for.
    ///
    /// Covers arrive in the cache by routes that do not touch this bookkeeping: a
    /// cover fetched on demand while scrolling, and every cover this device
    /// generated itself. Adopting them keeps the next pass from fetching what is
    /// already here. Only a file of exactly the expected size is adopted — the
    /// same check a fetch makes.
    @discardableResult
    func adoptLocalFiles() -> Int {
        do {
            let states = try statesByItemID()
            let inventory = Self.cacheInventory()
            var adopted = 0

            for book in try coverFacts() {
                guard book.coverVersion > 0, states[book.id]?.version != book.coverVersion else { continue }
                guard let bytes = inventory[book.id], bytes > 0,
                      book.coverBytes == 0 || bytes == book.coverBytes else { continue }

                let state = states[book.id] ?? {
                    let fresh = LocalCoverState(itemID: book.id)
                    modelContext.insert(fresh)
                    return fresh
                }()
                state.version = book.coverVersion
                state.bytes = bytes
                state.attempts = 0
                state.lastErrorCode = 0
                state.updatedAt = Date()
                adopted += 1
            }

            guard adopted > 0 else { return 0 }
            try modelContext.save()
            Self.logger.info("Adopted \(adopted, privacy: .public) thumbnails already in the cache")
            return adopted
        } catch {
            Self.logger.error("Could not adopt cached thumbnails: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Forgets the rows for books that are gone, so the table does not outgrow the
    /// library it describes.
    func forgetOrphanedStates() {
        do {
            let live = Set(try coverFacts().map(\.id))
            var removed = 0
            for state in try modelContext.fetch(FetchDescriptor<LocalCoverState>()) where !live.contains(state.itemID) {
                modelContext.delete(state)
                removed += 1
            }
            guard removed > 0 else { return }
            try modelContext.save()
            Self.logger.info("Forgot \(removed, privacy: .public) cover records for books that are gone")
        } catch {
            Self.logger.error("Could not tidy cover records: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Moves thumbnail files between the local cache and the distribution folder.
///
/// File work only, and deliberately outside the store's actor: a serialized actor
/// would copy one file at a time, and these transfers are latency-bound on a
/// share, where several at once is most of the speed.
enum ThumbnailTransfer {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "ThumbnailDistribution")

    /// Enough to keep a share busy without burying it. Small files over SMB wait
    /// on round trips rather than bandwidth, so one at a time wastes the link —
    /// and too many at once makes the NAS answer everything slowly, including the
    /// covers the person is looking at.
    static let defaultConcurrency = 6
    static let concurrencyRange = 2...16

    static func localFileURL(forItemID itemID: UUID) -> URL {
        ThumbnailCache.diskCacheDirectory.appendingPathComponent("\(itemID.uuidString).jpg")
    }

    /// Fetches a batch, several at a time, reporting each one as it lands.
    static func fetch(
        _ targets: [CoverFetchTarget],
        from root: URL,
        concurrency: Int = defaultConcurrency,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async -> [CoverFetchResult] {
        await run(targets, concurrency: concurrency, onProgress: onProgress) { target in
            do {
                let bytes = try ThumbnailDistribution.download(
                    forItemID: target.itemID,
                    from: root,
                    to: localFileURL(forItemID: target.itemID)
                )
                // The only check worth paying for. A wrong size means a torn or
                // stale file; a hash over twenty thousand covers buys nothing
                // that the next version would not fix anyway.
                if target.expectedBytes > 0, bytes != target.expectedBytes {
                    return CoverFetchResult(itemID: target.itemID, version: target.version, bytes: bytes,
                                            errorCode: NSFileReadCorruptFileError)
                }
                return CoverFetchResult(itemID: target.itemID, version: target.version, bytes: bytes, errorCode: nil)
            } catch {
                return CoverFetchResult(itemID: target.itemID, version: target.version, bytes: 0,
                                        errorCode: (error as NSError).code)
            }
        }
    }

    /// Hands a batch to the distribution folder.
    static func upload(
        _ targets: [CoverUploadTarget],
        to root: URL,
        concurrency: Int = defaultConcurrency,
        onProgress: @Sendable (Int) -> Void = { _ in }
    ) async -> [CoverFetchResult] {
        await run(targets, concurrency: concurrency, onProgress: onProgress) { target in
            let localFile = localFileURL(forItemID: target.itemID)
            do {
                let attributes = try? FileManager.default.attributesOfItem(atPath: localFile.path)
                let bytes = attributes?[.size] as? Int ?? 0
                try ThumbnailDistribution.upload(from: localFile, forItemID: target.itemID, to: root)
                return CoverFetchResult(itemID: target.itemID, version: target.version,
                                        bytes: bytes, errorCode: nil)
            } catch {
                return CoverFetchResult(itemID: target.itemID, version: target.version, bytes: 0,
                                        errorCode: (error as NSError).code)
            }
        }
    }

    /// The lane these transfers run on.
    ///
    /// Reading and writing files is blocking work, and a blocked thread in Swift's
    /// cooperative pool is one the rest of the app cannot have. That pool holds
    /// about as many threads as the machine has cores, so six transfers waiting on
    /// a share at once is most of it — everything else in the app, the scrolling
    /// included, waits behind them. A queue of its own keeps the waiting here.
    private static let transferQueue = DispatchQueue(
        label: "\(ThumbnailCache.appIdentifier).thumbnail-transfer",
        qos: .utility,
        attributes: .concurrent
    )

    /// Keeps `concurrency` transfers in flight until the list is done.
    private static func run<Target: Sendable>(
        _ targets: [Target],
        concurrency: Int,
        onProgress: @Sendable (Int) -> Void,
        transfer: @escaping @Sendable (Target) -> CoverFetchResult
    ) async -> [CoverFetchResult] {
        guard !targets.isEmpty else { return [] }
        let width = min(max(concurrency, concurrencyRange.lowerBound), concurrencyRange.upperBound)
        var results: [CoverFetchResult] = []
        results.reserveCapacity(targets.count)

        await withTaskGroup(of: CoverFetchResult.self) { group in
            func enqueue(_ target: Target) {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        transferQueue.async { continuation.resume(returning: transfer(target)) }
                    }
                }
            }

            var next = 0
            for _ in 0..<min(width, targets.count) {
                enqueue(targets[next])
                next += 1
            }

            while let result = await group.next() {
                results.append(result)
                onProgress(results.count)
                if Task.isCancelled { break }
                if next < targets.count {
                    enqueue(targets[next])
                    next += 1
                }
            }
            group.cancelAll()
        }

        let failed = results.filter { $0.errorCode != nil }.count
        if failed > 0 {
            logger.info("\(failed, privacy: .public) of \(results.count, privacy: .public) transfers did not complete")
        }
        return results
    }
}
