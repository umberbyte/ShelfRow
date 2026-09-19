//
//  LibraryStore.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// How the library store is open.
///
/// The store file is the same either way — only whether CloudKit mirrors it
/// changes. Keeping one file is what lets the setting be turned off and on
/// again without re-uploading the library or losing what has not been sent yet.
enum LibraryMode: String, Sendable {
    case local
    case cloud
}

enum LibraryStoreError: LocalizedError {
    case cloudKitUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: return CloudKitEntitlement.missingMessage
        }
    }
}

/// Decides which mode to open the library in, and records when that answer
/// has changed so the next launch can act on it.
@Observable
@MainActor
final class LibraryStore {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "LibraryStore")

    static let cloudContainerIdentifier = "iCloud.com.eureka.ShelfRow"

    private enum DefaultsKey {
        /// What the user asked for, which outlives a signed-out spell.
        static let syncEnabled = "iCloudSyncEnabled"
        /// What was actually opened last time, so startup does not wait on CloudKit.
        static let lastMode = "libraryLastEffectiveMode"
        /// Set when this device is to be re-seeded from iCloud. Acted on at the
        /// next launch, before any store is open.
        static let pendingLibraryReset = "libraryPendingResetFromCloud"
    }

    private(set) var mode: LibraryMode
    private(set) var container: ModelContainer
    private(set) var lastFailureMessage: String?

    /// Set once the open mode no longer matches what the setting and the account
    /// call for. Applying it takes a relaunch — see `persistRequestedMode`.
    private(set) var restartRequired = false

    /// A long-running job that must finish before the mode is changed under it
    /// (import, bulk cover generation, restore).
    var blockingTask: String?

    /// The user's setting, independent of whether iCloud is reachable right now.
    var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: DefaultsKey.syncEnabled) }
    }

    init() {
        StoreFileBackup.rotateStartupBackup()

        // Discarding this device's library has to happen with nothing holding the
        // files open, which only the moment before the first container exists can
        // promise. Deleting the rows instead would sync those deletions upward and
        // empty the library everywhere.
        if UserDefaults.standard.bool(forKey: DefaultsKey.pendingLibraryReset) {
            StoreFileBackup.removeStoreFiles()
            UserDefaults.standard.set(false, forKey: DefaultsKey.pendingLibraryReset)
            Self.logger.info("Cleared this device's library; it will be refilled from iCloud")
        }

        syncEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.syncEnabled)
        let requested = UserDefaults.standard.string(forKey: DefaultsKey.lastMode)
            .flatMap(LibraryMode.init(rawValue:)) ?? .local

        do {
            container = try Self.makeContainer(mode: requested)
            mode = requested
        } catch {
            Self.logger.error("Could not open the library in \(requested.rawValue, privacy: .public) mode: \(error.localizedDescription, privacy: .public)")
            guard let fallback = try? Self.makeContainer(mode: .local) else {
                fatalError("Could not open the library store: \(error)")
            }
            container = fallback
            mode = .local
            lastFailureMessage = "iCloud同期を開始できなかったため、ローカルで起動しました: \(error.localizedDescription)"
        }

        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.lastMode)
        BookmarkVault.shared.attach(to: container)
        BookmarkVault.shared.adoptBookmarksStoredOnModels()
    }

    /// The mode the app should be in. The setting alone is not enough: without an
    /// iCloud account the store must open locally, or signing out would take the
    /// library with it.
    nonisolated static func effectiveMode(syncEnabled: Bool, accountAvailable: Bool) -> LibraryMode {
        syncEnabled && accountAvailable ? .cloud : .local
    }

    /// Records what the next launch should open, and asks for a relaunch.
    ///
    /// Swapping the container while the app runs was tried and abandoned: SwiftUI
    /// keeps handing views and in-flight tasks the `Item`s belonging to the
    /// context that is being torn down, and reading any of them afterwards traps
    /// inside SwiftData ("this model instance was destroyed"). Choosing the mode
    /// before the first container exists is the only point where nothing holds a
    /// model at all.
    private func persistRequestedMode(_ target: LibraryMode) {
        UserDefaults.standard.set(target.rawValue, forKey: DefaultsKey.lastMode)
        restartRequired = target != mode
        Self.logger.info("Next launch will open the library in \(target.rawValue, privacy: .public) mode")
    }

    /// Turns syncing on with this device's library as the one that fills iCloud.
    /// Right for the first device; on any later one it would upload a second copy
    /// of books iCloud already holds, since nothing merges them.
    func enableSyncSeedingCloud() {
        StoreFileBackup.snapshotBeforeModeSwitch()
        syncEnabled = true
        persistRequestedMode(.cloud)
    }

    /// Turns syncing on by throwing this device's library away and taking
    /// iCloud's. Right for every device after the first. The deletion itself
    /// happens at the next launch (see `init`).
    func enableSyncReplacingLocalLibrary() {
        StoreFileBackup.snapshotBeforeModeSwitch()
        syncEnabled = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.pendingLibraryReset)
        persistRequestedMode(.cloud)
    }

    func disableSync() {
        syncEnabled = false
        persistRequestedMode(.local)
    }

    /// Signing out must not leave the store open through CloudKit, and signing
    /// back in should resume. Neither is urgent enough to restart the app out
    /// from under the user, so it is recorded and surfaced instead.
    func noteAccountAvailability(_ accountAvailable: Bool) {
        let target = Self.effectiveMode(syncEnabled: syncEnabled, accountAvailable: accountAvailable)
        guard target != mode else {
            restartRequired = false
            return
        }
        persistRequestedMode(target)
    }

    private static func makeContainer(mode: LibraryMode) throws -> ModelContainer {
        if mode == .cloud, !CloudKitEntitlement.isPresent {
            throw LibraryStoreError.cloudKitUnavailable
        }

        let directory = try StoreFileBackup.storeDirectory()
        let librarySchema = Schema([Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self])
        let localSchema = Schema([LocalBookmark.self])

        let library = ModelConfiguration(
            "Library",
            schema: librarySchema,
            url: directory.appendingPathComponent(StoreFileBackup.libraryStoreName),
            cloudKitDatabase: mode == .cloud ? .private(cloudContainerIdentifier) : .none
        )
        let local = ModelConfiguration(
            "Local",
            schema: localSchema,
            url: directory.appendingPathComponent(StoreFileBackup.localStoreName),
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self, LocalBookmark.self,
            configurations: library, local
        )
    }
}

// MARK: - Store file copies

/// Copies of the store files taken where losing them would be unrecoverable:
/// a rotating three deep at every launch, and one more before iCloud is first
/// allowed to touch the library.
enum StoreFileBackup {
    static let libraryStoreName = "default.store"
    static let localStoreName = "local.store"

    private static let maxGenerations = 3
    private static let startupBackupDirName = "StartupBackups"
    private static let modeSwitchBackupDirName = "ModeSwitchBackups"

    /// Every file SQLite keeps for a store — the WAL and shared-memory files hold
    /// writes that have not been checkpointed, so a copy without them is torn.
    private static var storeFileNames: [String] {
        [libraryStoreName, localStoreName].flatMap { [$0, "\($0)-wal", "\($0)-shm"] }
    }

    static func storeDirectory() throws -> URL {
        let directory = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// gen0 is newest, gen2 oldest. Failures are swallowed: a missing backup must
    /// never keep the app from starting.
    static func rotateStartupBackup() {
        guard let directory = try? storeDirectory() else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(libraryStoreName).path) else { return }

        let backupRoot = directory.appendingPathComponent(startupBackupDirName, isDirectory: true)
        try? fileManager.removeItem(at: backupRoot.appendingPathComponent("gen\(maxGenerations - 1)"))
        for generation in stride(from: maxGenerations - 2, through: 0, by: -1) {
            let source = backupRoot.appendingPathComponent("gen\(generation)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: backupRoot.appendingPathComponent("gen\(generation + 1)"))
        }

        copyStoreFiles(from: directory, to: backupRoot.appendingPathComponent("gen0"))
    }

    /// Deletes both stores. Only safe with no container open — see
    /// `LibraryStore.init`. The snapshot taken beforehand is the way back.
    static func removeStoreFiles() {
        guard let directory = try? storeDirectory() else { return }
        for name in storeFileNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func snapshotBeforeModeSwitch() {
        guard let directory = try? storeDirectory() else { return }
        let destination = directory.appendingPathComponent(modeSwitchBackupDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        copyStoreFiles(from: directory, to: destination)
    }

    private static func copyStoreFiles(from directory: URL, to destination: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in storeFileNames {
                let source = directory.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(at: source, to: destination.appendingPathComponent(name))
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            try stamp.write(to: destination.appendingPathComponent("backup_date.txt"), atomically: true, encoding: .utf8)
        } catch {
            // Never block startup or a mode switch because a copy failed.
        }
    }
}
