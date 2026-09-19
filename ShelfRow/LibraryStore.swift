//
//  LibraryStore.swift
//  ShelfRow
//

import AppKit
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
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        if Self.isRunningTests {
            let schema = Schema([Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self, LocalBookmark.self, LocalCoverState.self])
            guard let scratch = try? ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ) else {
                fatalError("Could not open an in-memory library for testing")
            }
            container = scratch
            mode = .local
            syncEnabled = false
            return
        }

        StoreFileBackup.rotateStartupBackup()

        // Discarding this device's library has to happen with nothing holding the
        // files open, which only the moment before the first container exists can
        // promise. Deleting the rows instead would sync those deletions upward and
        // empty the library everywhere.
        if UserDefaults.standard.bool(forKey: DefaultsKey.pendingLibraryReset) {
            Self.waitForOtherInstancesToExit()
            StoreFileBackup.removeStoreFiles()
            UserDefaults.standard.set(false, forKey: DefaultsKey.pendingLibraryReset)
            Self.logger.info("Cleared this device's library; it will be refilled from iCloud")
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
    func enableSyncSeedingCloud() {
        StoreFileBackup.snapshotBeforeModeSwitch()
        syncEnabled = true
        recordRole(.primary)
        persistRequestedMode(.cloud)
    }

    /// Turns syncing on by throwing this device's library away and taking
    /// iCloud's. Right for every device after the first. The deletion itself
    /// happens at the next launch (see `init`).
    func enableSyncReplacingLocalLibrary() {
        StoreFileBackup.snapshotBeforeModeSwitch()
        syncEnabled = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.pendingLibraryReset)
        recordRole(.replica)
        persistRequestedMode(.cloud)
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

    private static func makeContainer(mode: LibraryMode) throws -> ModelContainer {
        if mode == .cloud, !CloudKitEntitlement.isPresent {
            throw LibraryStoreError.cloudKitUnavailable
        }

        let directory = try StoreFileBackup.storeDirectory()
        let librarySchema = Schema([Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self])
        let localSchema = Schema([LocalBookmark.self, LocalCoverState.self])

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
