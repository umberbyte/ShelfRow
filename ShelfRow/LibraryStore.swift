//
//  LibraryStore.swift
//  ShelfRow
//

import AppKit
import Foundation
import OSLog
import SQLite3
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

/// Which side a device took when syncing was turned on.
///
/// Only the device that filled iCloud has any business changing what is in it.
/// A device that took iCloud's copy holds no authority over the library — its
/// own contents came from somewhere else — so the actions that reach into
/// iCloud are not offered there.
enum CloudRole: String, Sendable {
    /// Filled iCloud from its own library.
    case primary
    /// Threw its library away and took iCloud's.
    case replica
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
        /// The replacement flow completed its backup before relaunch.
        static let pendingResetBackupReady = "libraryPendingResetBackupReady"
        /// Set when iCloud's copy is to be deleted. Acted on at the next launch,
        /// once the library is open without CloudKit attached to it.
        static let pendingCloudPurge = "libraryPendingCloudPurge"
        /// Which side this device took when syncing was turned on.
        static let cloudRole = "libraryCloudRole"
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

    /// While the library is being queued for upload again.
    private(set) var isResending = false
    private(set) var resendMessage: String?

    /// Which side this device took, or nil if it has never been asked — which is
    /// the case for a device that was syncing before the question was recorded.
    /// Unknown counts as primary: hiding what someone already had would be the
    /// worse mistake of the two.
    private(set) var cloudRole: CloudRole?

    /// Whether this device took iCloud's library rather than filling it.
    var isReplica: Bool { cloudRole == .replica }

    /// The user's setting, independent of whether iCloud is reachable right now.
    var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: DefaultsKey.syncEnabled) }
    }

    /// This scheme runs its tests inside the app, so launching for a test would
    /// otherwise open the real library — and, once syncing is on, hand it to
    /// CloudKit — while the tests build containers of their own beside it. That
    /// costs the person's data a needless open on every run, and the two
    /// coordinators fight badly enough to take the test host down.
    private static var isRunningTests: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--keyboard-navigation-test") { return true }
        #endif
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        if Self.isRunningTests {
            let schema = Schema(Self.libraryModels + Self.localModels)
            guard let scratch = try? ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ) else {
                fatalError("Could not open an in-memory library for testing")
            }
            container = scratch
            mode = .local
            syncEnabled = false
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--keyboard-navigation-test") {
                let count = ProcessInfo.processInfo.arguments.contains("--large-library-test") ? 20_000 : 36
                for number in 0..<count {
                    let item = Item(relativePath: "keyboard-fixture-\(number).zip", title: String(format: "Keyboard row %02d", number), author: "")
                    scratch.mainContext.insert(item)
                }
                do {
                    try scratch.mainContext.save()
                } catch {
                    Self.logger.error("Could not seed keyboard test library: \(error.localizedDescription, privacy: .public)")
                }
            }
            #endif
            return
        }

        // Discarding this device's library has to happen with nothing holding the
        // files open, which only the moment before the first container exists can
        // promise. Deleting the rows instead would sync those deletions upward and
        // empty the library everywhere.
        if UserDefaults.standard.bool(forKey: DefaultsKey.pendingLibraryReset) {
            Self.waitForOtherInstancesToExit()
            let backupReady = UserDefaults.standard.bool(forKey: DefaultsKey.pendingResetBackupReady)
                || StoreFileBackup.snapshotBeforeModeSwitch()
            if backupReady {
                StoreFileBackup.removeStoreFiles()
                UserDefaults.standard.set(false, forKey: DefaultsKey.pendingLibraryReset)
                UserDefaults.standard.set(false, forKey: DefaultsKey.pendingResetBackupReady)
                Self.logger.info("Cleared this device's library; it will be refilled from iCloud")
            } else {
                // Keep both the store and the pending request intact. Opening
                // this local data through CloudKit now could merge the two
                // libraries, which is precisely what this flow must avoid.
                UserDefaults.standard.set(LibraryMode.local.rawValue, forKey: DefaultsKey.lastMode)
                lastFailureMessage = "切り替え前のバックアップを作成できなかったため、ローカルの蔵書を保持しました。"
                Self.logger.error("Did not replace the local library because its backup failed")
            }
        }

        syncEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.syncEnabled)
        cloudRole = UserDefaults.standard.string(forKey: DefaultsKey.cloudRole)
            .flatMap(CloudRole.init(rawValue:))
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
        Self.logger.info("Opened the library in \(self.mode.rawValue, privacy: .public) mode")
        BookmarkVault.shared.attach(to: container)
        BookmarkVault.shared.adoptBookmarksStoredOnModels()
        StoreFileBackup.scheduleStartupBackup()
    }

    /// Waits for the instance being replaced to finish quitting.
    ///
    /// A mode change is applied by launching a second instance and then quitting
    /// the first, so the new one reaches this point with the old one still
    /// holding the store files open. Deleting them there leaves the old process
    /// writing to files that no longer have a name, which SQLite reports as
    /// "database integrity compromised by API violation: vnode unlinked while in
    /// use". Nothing is lost when that happens — the old process is on its way
    /// out — but the store it is writing to is the one being replaced, and the
    /// guarantee this code is built on is that no container is open.
    private static func waitForOtherInstancesToExit(timeout: TimeInterval = 10) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.processIdentifier != ownProcess && !$0.isTerminated }
            guard !others.isEmpty else { return }
            Thread.sleep(forTimeInterval: 0.2)
        }

        logger.error("The previous instance is still running; replacing the library anyway")
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
    func enableSyncSeedingCloud() async -> Bool {
        guard await prepareModeSwitchBackup() else { return false }
        syncEnabled = true
        recordRole(.primary)
        persistRequestedMode(.cloud)
        return true
    }

    /// Turns syncing on by throwing this device's library away and taking
    /// iCloud's. Right for every device after the first. The deletion itself
    /// happens at the next launch (see `init`).
    func enableSyncReplacingLocalLibrary() async -> Bool {
        guard await prepareModeSwitchBackup() else { return false }
        syncEnabled = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.pendingLibraryReset)
        UserDefaults.standard.set(true, forKey: DefaultsKey.pendingResetBackupReady)
        recordRole(.replica)
        persistRequestedMode(.cloud)
        return true
    }

    private func prepareModeSwitchBackup() async -> Bool {
        blockingTask = "切り替え前のバックアップ"
        let succeeded = await Task.detached(priority: .utility) {
            StoreFileBackup.snapshotBeforeModeSwitch()
        }.value
        blockingTask = nil
        if !succeeded {
            lastFailureMessage = "切り替え前のバックアップを作成できなかったため、iCloud設定を変更しませんでした。"
        }
        return succeeded
    }

    private func recordRole(_ role: CloudRole?) {
        cloudRole = role
        if let role {
            UserDefaults.standard.set(role.rawValue, forKey: DefaultsKey.cloudRole)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.cloudRole)
        }
    }

    /// Queues the whole library for upload again. For the case the store's
    /// bookkeeping says everything has been sent and iCloud disagrees — see
    /// `CloudResender`.
    func resendEverythingToCloud() async {
        guard mode == .cloud, !isResending else { return }

        isResending = true
        resendMessage = nil
        blockingTask = "iCloudへの全件再送信"
        let resender = CloudResender(modelContainer: container)

        do {
            let queued = try await resender.resendEverything()
            resendMessage = "\(queued.formatted())件をiCloudへの送信待ちに入れました。送信が終わるまでこのままにしてください。"
        } catch {
            Self.logger.error("Could not queue the library for upload: \(error.localizedDescription, privacy: .public)")
            resendMessage = "再送信の準備に失敗しました: \(error.localizedDescription)"
        }

        blockingTask = nil
        isResending = false
    }

    func disableSync() {
        syncEnabled = false
        persistRequestedMode(.local)
    }

    /// Turns syncing off and asks for iCloud's copy to be deleted.
    ///
    /// The deletion waits for the next launch: with CloudKit still mirroring
    /// this store, removing the zone only prompts it to upload everything again.
    /// The caller is expected to restart the app.
    func requestCloudPurge() {
        syncEnabled = false
        UserDefaults.standard.set(true, forKey: DefaultsKey.pendingCloudPurge)
        // With iCloud emptied there is no copy left to have come from, so the
        // next time syncing is turned on the question is open again.
        recordRole(nil)
        persistRequestedMode(.local)
        Self.logger.info("iCloud's copy will be deleted on the next launch")
    }

    /// True once, when a purge was asked for and the library is open in a mode
    /// that makes it safe to carry out.
    func consumePendingCloudPurge() -> Bool {
        guard mode == .local,
              UserDefaults.standard.bool(forKey: DefaultsKey.pendingCloudPurge) else {
            return false
        }
        UserDefaults.standard.set(false, forKey: DefaultsKey.pendingCloudPurge)
        return true
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

    /// What iCloud mirrors.
    nonisolated static let libraryModels: [any PersistentModel.Type] =
        [Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self]

    /// What stays on this device: access to files, and which covers it holds.
    nonisolated static let localModels: [any PersistentModel.Type] =
        [LocalBookmark.self, LocalCoverState.self]

    /// Named in one place on purpose. A model listed in a configuration's schema
    /// but missing from the container's own is not a compile error — it is
    /// `configurationSchemaNotFoundInContainerSchema` at launch, which the store
    /// cannot open and the app cannot start from.
    private static func makeContainer(mode: LibraryMode) throws -> ModelContainer {
        if mode == .cloud, !CloudKitEntitlement.isPresent {
            throw LibraryStoreError.cloudKitUnavailable
        }

        let directory = try StoreFileBackup.storeDirectory()
        let librarySchema = Schema(libraryModels)
        let localSchema = Schema(localModels)

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

        return try ModelContainer(for: Schema(libraryModels + localModels), configurations: library, local)
    }
}

// MARK: - Store file copies

/// Transactional store snapshots taken where losing data would be unrecoverable:
/// a delayed, daily rotating set and one more before the iCloud mode changes.
nonisolated enum StoreFileBackup {
    static let libraryStoreName = "default.store"
    static let localStoreName = "local.store"

    private static let maxGenerations = 3
    private static let minimumStartupBackupInterval: TimeInterval = 24 * 60 * 60
    private static let startupBackupDirName = "StartupBackups"
    private static let modeSwitchBackupDirName = "ModeSwitchBackups"
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "StoreBackup")

    /// Every file SQLite keeps for a store — the WAL and shared-memory files hold
    /// writes that have not been checkpointed, so a copy without them is torn.
    private static var storeArtifactNames: [String] {
        [libraryStoreName, localStoreName].flatMap { [$0, "\($0)-wal", "\($0)-shm"] }
    }

    static func storeDirectory() throws -> URL {
        let directory = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A SQLite backup reads a transactionally consistent snapshot from the live
    /// store, including committed WAL contents, so it can run after the window is
    /// available without copying a potentially gigabyte-sized WAL beside the DB.
    /// It is deliberately delayed and limited to once per day: launch should not
    /// compete with the first list render or thumbnail reconciliation.
    static func scheduleStartupBackup() {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            createStartupBackupIfNeeded()
        }
    }

    nonisolated static func needsStartupBackup(
        lastBackupDate: Date?,
        now: Date = Date(),
        minimumInterval: TimeInterval = minimumStartupBackupInterval
    ) -> Bool {
        guard let lastBackupDate else { return true }
        return now.timeIntervalSince(lastBackupDate) >= minimumInterval
    }

    /// gen0 is newest, gen2 oldest. A new generation is only rotated into place
    /// after both database snapshots have completed successfully.
    private static func createStartupBackupIfNeeded() {
        guard let directory = try? storeDirectory() else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(libraryStoreName).path) else { return }

        let backupRoot = directory.appendingPathComponent(startupBackupDirName, isDirectory: true)
        let newest = backupRoot.appendingPathComponent("gen0", isDirectory: true)
        let hasLegacyCopies = (0..<maxGenerations).contains { generation in
            let copy = backupRoot.appendingPathComponent("gen\(generation)", isDirectory: true)
            return ["\(libraryStoreName)-wal", "\(libraryStoreName)-shm",
                    "\(localStoreName)-wal", "\(localStoreName)-shm"].contains {
                fileManager.fileExists(atPath: copy.appendingPathComponent($0).path)
            }
        }
        let lastBackupDate = (try? fileManager.attributesOfItem(
            atPath: newest.appendingPathComponent("backup_date.txt").path
        )[.modificationDate]) as? Date
        guard hasLegacyCopies || needsStartupBackup(lastBackupDate: lastBackupDate) else { return }

        let staging = backupRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try snapshotDatabases(from: directory, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            logger.error("Could not create the scheduled store backup: \(error.localizedDescription, privacy: .public)")
            return
        }

        if hasLegacyCopies {
            // The former format copied WAL/SHM files verbatim and could consume
            // more than a gigabyte. Once a valid SQLite snapshot exists, retire
            // those generations as a unit rather than leaving torn databases.
            for generation in 0..<maxGenerations {
                try? fileManager.removeItem(at: backupRoot.appendingPathComponent("gen\(generation)"))
            }
        } else {
            try? fileManager.removeItem(at: backupRoot.appendingPathComponent("gen\(maxGenerations - 1)"))
            for generation in stride(from: maxGenerations - 2, through: 0, by: -1) {
                let source = backupRoot.appendingPathComponent("gen\(generation)")
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.moveItem(at: source, to: backupRoot.appendingPathComponent("gen\(generation + 1)"))
            }
        }
        do {
            try fileManager.moveItem(at: staging, to: newest)
            logger.info("Created the scheduled SQLite store backup")
        } catch {
            logger.error("Could not install the scheduled store backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes both stores. Only safe with no container open — see
    /// `LibraryStore.init`. The snapshot taken beforehand is the way back.
    static func removeStoreFiles() {
        guard let directory = try? storeDirectory() else { return }
        for name in storeArtifactNames {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    @discardableResult
    static func snapshotBeforeModeSwitch() -> Bool {
        guard let directory = try? storeDirectory() else { return false }
        let destination = directory.appendingPathComponent(modeSwitchBackupDirName, isDirectory: true)
        let staging = directory.appendingPathComponent(".mode-switch-backup-\(UUID().uuidString)", isDirectory: true)
        do {
            try snapshotDatabases(from: directory, to: staging)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            logger.error("Could not create the mode-switch store backup: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func snapshotDatabases(from directory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in [libraryStoreName, localStoreName] {
            let source = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try snapshotDatabase(from: source, to: destination.appendingPathComponent(name))
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try stamp.write(to: destination.appendingPathComponent("backup_date.txt"), atomically: true, encoding: .utf8)
    }

    private static func snapshotDatabase(from source: URL, to destination: URL) throws {
        var sourceDatabase: OpaquePointer?
        var destinationDatabase: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDatabase, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            defer { sqlite3_close(sourceDatabase) }
            throw StoreBackupError.cannotOpenSource(source.lastPathComponent)
        }
        defer { sqlite3_close(sourceDatabase) }

        try? FileManager.default.removeItem(at: destination)
        guard sqlite3_open_v2(
            destination.path,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            defer { sqlite3_close(destinationDatabase) }
            throw StoreBackupError.cannotOpenDestination(destination.lastPathComponent)
        }
        defer { sqlite3_close(destinationDatabase) }

        guard let backup = sqlite3_backup_init(destinationDatabase, "main", sourceDatabase, "main") else {
            throw StoreBackupError.cannotStart(source.lastPathComponent)
        }
        defer { sqlite3_backup_finish(backup) }

        while true {
            switch sqlite3_backup_step(backup, 512) {
            case SQLITE_DONE:
                return
            case SQLITE_OK:
                continue
            case SQLITE_BUSY, SQLITE_LOCKED:
                sqlite3_sleep(10)
            default:
                throw StoreBackupError.copyFailed(source.lastPathComponent)
            }
        }
    }
}

nonisolated private enum StoreBackupError: LocalizedError {
    case cannotOpenSource(String)
    case cannotOpenDestination(String)
    case cannotStart(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenSource(let name): return "\(name)を読み取り用に開けませんでした。"
        case .cannotOpenDestination(let name): return "\(name)のバックアップを作成できませんでした。"
        case .cannotStart(let name): return "\(name)のSQLiteバックアップを開始できませんでした。"
        case .copyFailed(let name): return "\(name)のSQLiteバックアップ中にエラーが発生しました。"
        }
    }
}
