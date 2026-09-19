//
//  CoverExtractionRecord.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// What extracting a cover for one book concluded.
enum CoverExtractionOutcome: String, Sendable {
    /// A thumbnail was produced with the current heuristic.
    case generated
    /// The file opened, but holds no page usable as a cover.
    case noUsableCover
}

/// Bulk cover generation's record of what it has already concluded, per book.
///
/// Extraction is deterministic, so without this the bulk pass keeps redoing its
/// own work: a book whose best page really is a spread or a monochrome page
/// produces a thumbnail that looks wrong by the very rules that asked for it, and
/// a book with nothing usable inside produces no file at all, which reads as "not
/// generated yet". Both would be re-read on every run, forever.
///
/// This table belongs to cover generation alone — nothing else in the app reads
/// it. A book that could not be opened at all is deliberately never recorded:
/// that answer can change by the next run.
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

/// The records as plain values, for the scan that runs off the model context.
struct CoverExtractionStates: Sendable {
    var generated: Set<UUID> = []
    var withoutCover: Set<UUID> = []
}

/// Reads and writes `CoverExtractionRecord` off the main actor, so a library-sized
/// batch of them never lands on the thread drawing the UI.
@ModelActor
actor CoverExtractionStore {
    private static let logger = Logger(subsystem: "jp.aromatics.ShelfRow", category: "CoverExtraction")

    func states() -> CoverExtractionStates {
        var states = CoverExtractionStates()
        do {
            for record in try modelContext.fetch(FetchDescriptor<CoverExtractionRecord>()) {
                switch record.outcome {
                case .generated:
                    states.generated.insert(record.itemID)
                case .noUsableCover:
                    states.withoutCover.insert(record.itemID)
                case nil:
                    continue
                }
            }
        } catch {
            Self.logger.error("Could not read cover extraction records: \(error.localizedDescription, privacy: .public)")
        }
        return states
    }

    func record(generated: [UUID], withoutCover: [UUID]) {
        guard !generated.isEmpty || !withoutCover.isEmpty else { return }

        do {
            let existing = try modelContext.fetch(FetchDescriptor<CoverExtractionRecord>())
            var recordsByItemID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Date()

            // The latest conclusion replaces the previous one, so a book that has a
            // cover now stops counting as one without a cover, and the other way round.
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

            apply(generated, .generated)
            apply(withoutCover, .noUsableCover)
            try modelContext.save()
        } catch {
            Self.logger.error("Could not save cover extraction records: \(error.localizedDescription, privacy: .public)")
        }
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

        record(generated: generated, withoutCover: withoutCover)
        try? FileManager.default.removeItem(at: generatedOnlyURL)
        try? FileManager.default.removeItem(at: outcomesURL)
    }

    private struct LegacyExtractionLog: Codable {
        var generated: Set<UUID>
        var withoutCover: Set<UUID>
    }
}
