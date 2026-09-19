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
            let message = event.error?.localizedDescription
            MainActor.assumeIsolated {
                self?.recordSyncEvent(succeeded: succeeded, errorMessage: message)
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

    private func recordSyncEvent(succeeded: Bool, errorMessage: String?) {
        lastSyncDate = Date()
        lastSyncErrorMessage = succeeded ? nil : errorMessage
        if let errorMessage, !succeeded {
            Self.logger.error("CloudKit sync event failed: \(errorMessage, privacy: .public)")
        }
    }
}
