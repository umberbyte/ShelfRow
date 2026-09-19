//
//  CloudAccount.swift
//  ShelfRow
//

import CloudKit
import CoreData
import Foundation
import OSLog
import Security

/// Whether this build may talk to the app's CloudKit container.
///
/// `CKContainer(identifier:)` traps rather than throwing when the executable was
/// not signed with a matching container entitlement — which is the normal state
/// of an unsigned local build — so every path into CloudKit has to ask first.
enum CloudKitEntitlement {
    static let isPresent: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return identifiers.contains(LibraryStore.cloudContainerIdentifier)
    }()

    static let missingMessage = "このビルドにiCloudの利用権限が含まれていません（署名なしビルドなど）。"
}

/// Watches the iCloud account and the sync traffic SwiftData generates, so the
/// app can open the library in the right mode and say why when it cannot.
@Observable
@MainActor
final class CloudAccountMonitor {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "CloudAccount")

    enum Availability: Equatable {
        case checking
        case available
        case noAccount
        case restricted
        /// Temporarily unavailable, undetermined, or the container refused us.
        case unavailable(String)

        var isAvailable: Bool { self == .available }

        var statusText: String {
            switch self {
            case .checking: return "iCloudの状態を確認中…"
            case .available: return "利用可能"
            case .noAccount: return "iCloudにサインインしていません"
            case .restricted: return "iCloudの利用が制限されています"
            case .unavailable(let reason): return "iCloudを利用できません: \(reason)"
            }
        }
    }

    private(set) var availability: Availability = .checking
    /// Opaque per-account identifier. CloudKit does not hand out the address or
    /// the name, but this is stable across a person's own devices, which is what
    /// makes it worth showing: two devices that match are the same account.
    private(set) var userRecordName: String?
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncErrorMessage: String?
    /// When CloudKit asked us to back off. Seeding a large library earns this
    /// routinely — the framework waits and carries on by itself, so it is a
    /// state to report, not a failure to warn about.
    private(set) var throttledUntil: Date?
    /// The result of the last deletion of this app's iCloud data, kept so the
    /// settings pane can report it after the relaunch that carried it out.
    private(set) var lastPurgeMessage: String?

    var isThrottled: Bool {
        guard let throttledUntil else { return false }
        return throttledUntil > Date()
    }

    /// Whether iCloud is still working through changes.
    ///
    /// CloudKit reports that a round finished and nothing about what is left, so
    /// there is no count to show and no bar to fill — only whether rounds are
    /// still arriving. They come every few seconds during a large upload, so a
    /// long enough gap means it has settled.
    private(set) var isSyncing = false

    private static let settledAfter: TimeInterval = 90
    private var settleTask: Task<Void, Never>?

    /// Held for the lifetime of the app — the monitor is created once by the
    /// `App` and never torn down, so there is no point at which to unregister.
    private var observers: [NSObjectProtocol] = []

    /// Called whenever the account's availability changes, so the store can be
    /// reopened in the matching mode.
    var onAvailabilityChange: ((Bool) -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        guard CloudKitEntitlement.isPresent else {
            availability = .unavailable(CloudKitEntitlement.missingMessage)
            return
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // `Event` is a non-Sendable class, so everything needed is read here,
            // on the main queue the notification was delivered to.
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            let succeeded = event.succeeded
            let error = event.error as? NSError
            let message = error?.localizedDescription
            let retryAfter = Self.retryInterval(for: error)
            MainActor.assumeIsolated {
                self?.recordSyncEvent(succeeded: succeeded, errorMessage: message, retryAfter: retryAfter)
            }
        })

        Task { await refresh() }
    }

    func refresh() async {
        guard CloudKitEntitlement.isPresent else {
            availability = .unavailable(CloudKitEntitlement.missingMessage)
            return
        }

        let previous = availability.isAvailable
        let container = CKContainer(identifier: LibraryStore.cloudContainerIdentifier)

        do {
            switch try await container.accountStatus() {
            case .available:
                availability = .available
            case .noAccount:
                availability = .noAccount
                userRecordName = nil
            case .restricted:
                availability = .restricted
                userRecordName = nil
            case .couldNotDetermine:
                availability = .unavailable("状態を判別できませんでした")
            case .temporarilyUnavailable:
                availability = .unavailable("一時的に利用できません")
            @unknown default:
                availability = .unavailable("未知の状態")
            }
        } catch {
            Self.logger.error("Could not read the iCloud account status: \(error.localizedDescription, privacy: .public)")
            availability = .unavailable(error.localizedDescription)
        }

        if availability.isAvailable, userRecordName == nil {
            do {
                userRecordName = try await container.userRecordID().recordName
            } catch {
                // Not fatal: the account is usable, we just cannot label it.
                Self.logger.error("Could not read the iCloud user record: \(error.localizedDescription, privacy: .public)")
            }
        }

        if previous != availability.isAvailable {
            onAvailabilityChange?(availability.isAvailable)
        }
    }

    /// Deletes everything this app holds in iCloud, so someone leaving can take
    /// their storage back.
    ///
    /// Every custom zone in the container's private database is removed; the
    /// container belongs to this app alone, so nothing there is anyone else's.
    /// This must run with the library open *without* CloudKit — mirroring would
    /// notice the zone go and upload the whole library again to replace it.
    func purgeCloudStorage() async {
        guard CloudKitEntitlement.isPresent else {
            lastPurgeMessage = CloudKitEntitlement.missingMessage
            return
        }

        let database = CKContainer(identifier: LibraryStore.cloudContainerIdentifier).privateCloudDatabase
        do {
            let zones = try await database.allRecordZones()
            // The default zone cannot be deleted and holds nothing of ours.
            let ours = zones.map(\.zoneID).filter { $0.zoneName != CKRecordZone.ID.defaultZoneName }
            for zoneID in ours {
                _ = try await database.deleteRecordZone(withID: zoneID)
            }
            Self.logger.info("Deleted \(ours.count, privacy: .public) iCloud zone(s)")
            lastSyncDate = nil
            lastSyncErrorMessage = nil
            throttledUntil = nil
            isSyncing = false
            settleTask?.cancel()
            lastPurgeMessage = ours.isEmpty
                ? "iCloudにこのアプリのデータはありませんでした。"
                : "iCloudのデータを削除しました。使用していた容量は解放されます。"
        } catch {
            Self.logger.error("Could not delete this app's iCloud data: \(error.localizedDescription, privacy: .public)")
            lastPurgeMessage = "iCloudのデータを削除できませんでした: \(error.localizedDescription)"
        }
    }

    /// How long CloudKit wants us to wait, for the errors it expects to pass on
    /// their own. Asking for the retry interval rather than matching error codes
    /// keeps this to the one question that matters: will waiting fix it?
    nonisolated static func retryInterval(for error: NSError?) -> TimeInterval? {
        // The event's error is sometimes the CloudKit one and sometimes wraps it,
        // so follow the chain rather than trusting the outermost layer.
        var current = error
        var depth = 0
        while let error = current, depth < 4 {
            if error.domain == CKErrorDomain {
                if let retryAfter = error.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
                    return retryAfter
                }
                // These pass on their own whether or not an interval came with
                // them: throttling and a busy zone are what seeding a large
                // library earns, and being offline ends when the network returns.
                switch CKError.Code(rawValue: error.code) {
                case .requestRateLimited, .serviceUnavailable, .zoneBusy,
                     .networkUnavailable, .networkFailure:
                    return 0
                default:
                    break
                }
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }

    private func recordSyncEvent(succeeded: Bool, errorMessage: String?, retryAfter: TimeInterval?) {
        lastSyncDate = Date()
        markSyncing()

        guard !succeeded else {
            lastSyncErrorMessage = nil
            throttledUntil = nil
            return
        }

        if let retryAfter {
            throttledUntil = Date().addingTimeInterval(retryAfter)
            lastSyncErrorMessage = nil
            Self.logger.info("CloudKit asked us to wait \(retryAfter, format: .fixed(precision: 1), privacy: .public)s; it will retry on its own")
            return
        }

        throttledUntil = nil
        lastSyncErrorMessage = errorMessage
        if let errorMessage {
            Self.logger.error("CloudKit sync event failed: \(errorMessage, privacy: .public)")
        }
    }

    /// Holds `isSyncing` true until rounds stop arriving. Rescheduling on every
    /// event measures the quiet gap from the last one rather than the first.
    private func markSyncing() {
        isSyncing = true
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settledAfter))
            guard !Task.isCancelled else { return }
            self?.isSyncing = false
        }
    }
}
