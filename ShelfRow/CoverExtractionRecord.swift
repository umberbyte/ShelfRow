//
//  CoverExtractionRecord.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// What extracting a cover for one book concluded.
enum CoverExtractionOutcome: String, Sendable {
    /// A thumbnail was produced and written to the cache.
    case generated
    /// The file opened, but holds no page usable as a cover.
    case noUsableCover
    /// The file could not be opened at all — volume unmounted, moved, deleted.
    case unreachable
}

/// Bulk cover generation's record of the books it has already been run against.
///
/// A book is attempted once and then left alone, whatever came of it. Extraction
/// is deterministic, so a second attempt re-reads the archive to reach the answer
/// already stored here: the same spread or monochrome page that looks wrong by the
/// very rules that asked for it, or the same nothing-usable-inside that leaves no
/// file and so reads as "not generated yet".
///
/// This table belongs to cover generation alone — nothing else in the app reads
/// it. The outcome is kept per book so a run can report what happened, but the
/// decision to skip only asks whether a record exists.
@Model
final class CoverExtractionRecord {
    @Attribute(.unique) var itemID: UUID
    var outcomeRaw: String
    var updatedAt: Date

    var outcome: CoverExtractionOutcome? {
        CoverExtractionOutcome(rawValue: outcomeRaw)
    }

    init(itemID: UUID, outcome: CoverExtractionOutcome, updatedAt: Date = Date()) {
        self.itemID = itemID
        self.outcomeRaw = outcome.rawValue
        self.updatedAt = updatedAt
    }
}

/// What one bulk run concluded, ready to be written back as records.
struct CoverExtractionOutcomes: Sendable {
    var generated: [UUID] = []
    var withoutCover: [UUID] = []
    var unreachable: [UUID] = []

    var isEmpty: Bool {
        generated.isEmpty && withoutCover.isEmpty && unreachable.isEmpty
    }
}

/// Reads and writes `CoverExtractionRecord` off the main actor, so a library-sized
/// batch of them never lands on the thread drawing the UI.
@ModelActor
actor CoverExtractionStore {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "CoverExtraction")

    /// The books generation has already been run against, whatever came of it.
    func attemptedItemIDs() -> Set<UUID> {
        do {
            let records = try modelContext.fetch(FetchDescriptor<CoverExtractionRecord>())
            Self.logger.info("Cover generation has \(records.count, privacy: .public) books on record")
            return Set(records.map(\.itemID))
        } catch {
            Self.logger.error("Could not read cover extraction records: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func record(_ outcomes: CoverExtractionOutcomes) {
        guard !outcomes.isEmpty else { return }

        do {
            let existing = try modelContext.fetch(FetchDescriptor<CoverExtractionRecord>())
            var recordsByItemID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Date()

            func apply(_ itemIDs: [UUID], _ outcome: CoverExtractionOutcome) {
                for itemID in itemIDs {
                    if let record = recordsByItemID[itemID] {
                        record.outcomeRaw = outcome.rawValue
                        record.updatedAt = now
                    } else {
                        let record = CoverExtractionRecord(itemID: itemID, outcome: outcome, updatedAt: now)
                        modelContext.insert(record)
                        recordsByItemID[itemID] = record
                    }
                }
            }

            apply(outcomes.generated, .generated)
            apply(outcomes.withoutCover, .noUsableCover)
            apply(outcomes.unreachable, .unreachable)
            try modelContext.save()

            Self.logger.info("""
                Recorded cover generation: \(outcomes.generated.count, privacy: .public) generated, \
                \(outcomes.withoutCover.count, privacy: .public) without a usable cover, \
                \(outcomes.unreachable.count, privacy: .public) unreachable
                """)
        } catch {
            Self.logger.error("Could not save cover extraction records: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks one book as settled, for a cover chosen outside a bulk run.
    func recordGenerated(_ itemID: UUID) {
        record(CoverExtractionOutcomes(generated: [itemID]))
    }

    /// Drops records for books that are no longer in the library.
    func prune(keeping itemIDs: Set<UUID>) {
        do {
            let records = try modelContext.fetch(FetchDescriptor<CoverExtractionRecord>())
            let orphans = records.filter { !itemIDs.contains($0.itemID) }
            guard !orphans.isEmpty else { return }

            for orphan in orphans {
                modelContext.delete(orphan)
            }
            try modelContext.save()
        } catch {
            Self.logger.error("Could not prune cover extraction records: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Carries over the JSON files earlier builds kept this in, then removes them.
    /// Can be deleted once every install has run bulk generation again.
    func importLegacyLogs() {
        let directory = ThumbnailCache.diskCacheDirectory
        let generatedOnlyURL = directory.appendingPathComponent("generated-covers.json")
        let outcomesURL = directory.appendingPathComponent("cover-extraction-log.json")

        var generated: [UUID] = []
        var withoutCover: [UUID] = []

        if let data = try? Data(contentsOf: generatedOnlyURL),
           let itemIDs = try? JSONDecoder().decode([UUID].self, from: data) {
            generated.append(contentsOf: itemIDs)
        }
        if let data = try? Data(contentsOf: outcomesURL),
           let log = try? JSONDecoder().decode(LegacyExtractionLog.self, from: data) {
            generated.append(contentsOf: log.generated)
            withoutCover.append(contentsOf: log.withoutCover)
        }

        guard !generated.isEmpty || !withoutCover.isEmpty else { return }

        record(CoverExtractionOutcomes(generated: generated, withoutCover: withoutCover))
        try? FileManager.default.removeItem(at: generatedOnlyURL)
        try? FileManager.default.removeItem(at: outcomesURL)
    }

    private struct LegacyExtractionLog: Codable {
        var generated: Set<UUID>
        var withoutCover: Set<UUID>
    }
}
