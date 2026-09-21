//
//  CloudUploadBacklog.swift
//  ShelfRow
//

import Foundation
import OSLog
import SQLite3
import SwiftData

/// How many records iCloud has not taken yet.
///
/// **This reads a private schema.** `NSPersistentCloudKitContainer.Event` says
/// that a round finished and never how much is left, and "no rounds lately" is
/// not the same answer: CloudKit throttles a large first upload into bursts
/// minutes apart, so a quiet spell looks exactly like being done. The count of
/// records still waiting is written down in one place only — the mirroring
/// delegate's own table, inside the store file.
///
/// Nothing here is API. An OS update may rename or restructure it, so the table
/// and column are found by pattern, every failure returns nil, and the caller
/// falls back to judging by whether rounds are still arriving.
/// What iCloud has taken, what it has not, and what this device holds.
///
/// There is deliberately no "still to receive" here. A record that has not
/// arrived has no row in this store to count, and CloudKit's change feed runs
/// until the server says it is empty rather than announcing a total up front —
/// so the number does not exist locally to be shown. On a device being filled,
/// `held` climbing is the arrival.
struct CloudUploadCounts: Sendable, Equatable {
    let pending: Int
    let uploaded: Int
    let held: Int
}

enum CloudUploadBacklog {
    private nonisolated static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "CloudUploadBacklog")

    nonisolated private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var unavailable = false
        private var didLogSchema = false

        var canProbe: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !unavailable
        }

        func stopProbing() {
            lock.lock()
            unavailable = true
            lock.unlock()
        }

        func claimSchemaLog() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didLogSchema else { return false }
            didLogSchema = true
            return true
        }
    }

    /// Once the private schema cannot be read, do not re-probe it every tick.
    private nonisolated static let probeState = ProbeState()

    /// Records still to upload and records already taken, or nil when the store
    /// will not say.
    @MainActor
    static func counts(container: ModelContainer) async -> CloudUploadCounts? {
        guard probeState.canProbe,
              let storeURL = container.configurations.first(where: { $0.name == "Library" })?.url else {
            return nil
        }
        guard var counts = await Task.detached(priority: .utility, operation: {
            recordCounts(storeURL: storeURL)
        }).value else { return nil }
        let held = await CloudHeldCountReader(modelContainer: container).count()
        counts = CloudUploadCounts(
            pending: counts.pending,
            uploaded: counts.uploaded,
            held: held
        )
        return counts
    }

    /// Opens a second, read-only connection to the store Core Data is writing.
    /// SQLite allows this; the shared-memory file it needs is already there
    /// because this process has the store open.
    nonisolated private static func recordCounts(storeURL: URL) -> CloudUploadCounts? {
        var database: OpaquePointer?
        let uri = storeURL.absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            markUnavailable("could not open the store read-only")
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        guard let table = mirroringMetadataTable(in: database) else {
            markUnavailable("no CloudKit metadata table in this store")
            return nil
        }
        // A row exists for every object from the moment it is queued, so the
        // rows themselves say nothing about progress — the flag on them does.
        guard let pendingColumn = column(matching: "%NEEDSUPLOAD%", of: table, in: database) else {
            markUnavailable("no upload flag on \(table)")
            return nil
        }
        // Both names come from sqlite_master / PRAGMA and are matched against
        // fixed patterns, so neither can carry anything but an identifier.
        guard let pending = singleValue(
            "SELECT COUNT(*) FROM \(table) WHERE \(pendingColumn) != 0", in: database
        ), let total = singleValue("SELECT COUNT(*) FROM \(table)", in: database) else {
            markUnavailable("could not count rows in \(table)")
            return nil
        }

        logOnce(table: table, column: pendingColumn, pending: pending, total: total)
        return CloudUploadCounts(pending: pending, uploaded: max(0, total - pending), held: 0)
    }

    nonisolated private static func column(matching pattern: String, of table: String, in database: OpaquePointer?) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let wanted = pattern.replacingOccurrences(of: "%", with: "")
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: raw)
            if name.uppercased().contains(wanted) { return name }
        }
        return nil
    }

    nonisolated private static func mirroringMetadataTable(in database: OpaquePointer?) -> String? {
        let query = """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND upper(name) LIKE '%CKRECORDMETADATA%'
            ORDER BY length(name) LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: name)
    }

    nonisolated private static func singleValue(_ query: String, in database: OpaquePointer?) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// One line, once per launch, so a schema that has drifted under an OS
    /// update can be recognised from the log rather than guessed at.
    nonisolated private static func logOnce(table: String, column: String, pending: Int, total: Int) {
        guard probeState.claimSchemaLog() else { return }
        logger.info("\(table, privacy: .public): \(pending, privacy: .public) of \(total, privacy: .public) rows still have \(column, privacy: .public) set")
    }

    nonisolated private static func markUnavailable(_ reason: String) {
        probeState.stopProbing()
        logger.info("Seed progress is unavailable (\(reason, privacy: .public)); falling back to activity only")
    }
}

@ModelActor
private actor CloudHeldCountReader {
    func count() -> Int {
        var held = 0
        held += (try? modelContext.fetchCount(FetchDescriptor<Item>())) ?? 0
        held += (try? modelContext.fetchCount(FetchDescriptor<Shelf>())) ?? 0
        held += (try? modelContext.fetchCount(FetchDescriptor<Volume>())) ?? 0
        held += (try? modelContext.fetchCount(FetchDescriptor<CoverExtractionRecord>())) ?? 0
        return held
    }
}
