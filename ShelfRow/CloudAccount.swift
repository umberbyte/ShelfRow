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

    var isThrottled: Bool {
        guard let throttledUntil else { return false }
        return throttledUntil > Date()
    }

    /// Completed export/import rounds since the app launched. CloudKit does not
    /// publish how many records a round carried, nor how many are left, so this
    /// counts activity rather than progress — enough to show that seeding is
    /// moving, not enough to put a percentage on it.
    private(set) var syncRoundsCompleted = 0
    private(set) var syncStartedAt: Date?

    /// Rounds arrive every few seconds while a large library is being seeded, so
    /// a gap this long means it has settled.
    private static let settledAfter: TimeInterval = 90

    var isSyncing: Bool {
        if isThrottled { return true }
        guard let lastSyncDate else { return false }
        return Date().timeIntervalSince(lastSyncDate) < Self.settledAfter
    }

    var syncElapsed: TimeInterval? {
        syncStartedAt.map { Date().timeIntervalSince($0) }
    }

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
        if syncStartedAt == nil || !isSyncing {
            syncStartedAt = Date()
            syncRoundsCompleted = 0
        }
        syncRoundsCompleted += 1
        lastSyncDate = Date()

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
}
