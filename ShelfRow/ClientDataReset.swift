import Foundation
import OSLog

/// Removes every database and cache owned by this Mac's ShelfRow client.
///
/// This must run before `ModelContainer` is created. Deleting SQLite files while
/// SwiftData or CloudKit still has them open can corrupt the store and can let an
/// old process recreate files after the reset appears to have finished.
nonisolated enum ClientDataReset {
    private static let logger = Logger(
        subsystem: ThumbnailCache.appIdentifier,
        category: "ClientDataReset"
    )

    static func clearClientData() throws {
        try clearContents(
            applicationSupportDirectory: URL.applicationSupportDirectory,
            cachesDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        )
    }

    static func clearContents(
        applicationSupportDirectory: URL,
        cachesDirectory: URL
    ) throws {
        try clearDirectory(applicationSupportDirectory)
        try clearDirectory(cachesDirectory)
        logger.info("Cleared this client's databases, support files, and caches")
    }

    private static func clearDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }

        // SQLite and SwiftData keep hidden support directories. A second pass
        // without `.skipsHiddenFiles` removes those while retaining the root URL.
        let hiddenChildren = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for child in hiddenChildren {
            try fileManager.removeItem(at: child)
        }
    }
}
