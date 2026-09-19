//
//  CloudResend.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// Queues the whole library for upload again, for when the store's own
/// bookkeeping has come to disagree with what iCloud actually holds.
///
/// CloudKit mirroring keeps a per-record "needs upload" flag beside the library,
/// and nothing public resets it. Moving a synced app from the development
/// container to the production one leaves every flag reading "sent" while the
/// production database is empty, and from there the library can never catch up:
/// as far as the store is concerned there is nothing left to send. Deleting the
/// zone does not help either — that clears the relationship bookkeeping, which
/// is why the relationship records go up again, but the flags on the records
/// themselves survive it.
///
/// Writing to each object is the way back, since every change raises the flag.
/// The write is undone in the same breath: a temporary value goes in, the chunk
/// is saved, the original value goes back, and it is saved again. What reaches
/// iCloud is the library exactly as it stands — only the bookkeeping changes.
///
/// The fields chosen to be written are ones nothing reads: the two `bookmarkData`
/// properties have been dead since bookmarks moved to the device-local store, and
/// the rest are restored before anything can look at them. A crash midway leaves
/// a chunk holding a temporary value, so none may be a value that would mislead
/// the app if it were read.
@ModelActor
actor CloudResender {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "CloudResend")

    /// Small enough that a save is quick and a crash costs little, large enough
    /// that a library-sized run is not thousands of transactions.
    private static let chunkSize = 200

    /// Touches every record CloudKit mirrors, and answers how many.
    func resendEverything() throws -> Int {
        var total = 0
        // Volumes and shelves first: the records books point at are worth having
        // in iCloud before the books that need them.
        total += try touch(\Volume.bookmarkData) { _ in Data([0]) }
        total += try touch(\Shelf.sortOrder) { $0 &+ 1 }
        total += try touch(\Item.bookmarkData) { _ in Data([0]) }
        total += try touch(\CoverExtractionRecord.updatedAt) { $0.addingTimeInterval(1) }
        Self.logger.info("Queued \(total, privacy: .public) records for upload again")
        return total
    }

    private func touch<Model: PersistentModel, Value>(
        _ keyPath: ReferenceWritableKeyPath<Model, Value>,
        temporary: (Value) -> Value
    ) throws -> Int {
        let models = try modelContext.fetch(FetchDescriptor<Model>())
        var touched = 0

        for start in stride(from: 0, to: models.count, by: Self.chunkSize) {
            let chunk = models[start..<min(start + Self.chunkSize, models.count)]
            let originals = chunk.map { $0[keyPath: keyPath] }

            for model in chunk {
                model[keyPath: keyPath] = temporary(model[keyPath: keyPath])
            }
            try modelContext.save()

            for (model, original) in zip(chunk, originals) {
                model[keyPath: keyPath] = original
            }
            try modelContext.save()

            touched += chunk.count
        }

        Self.logger.info("Queued \(touched, privacy: .public) \(String(describing: Model.self), privacy: .public) records")
        return touched
    }
}
