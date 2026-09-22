import Combine
import CoreData
import Foundation
import SwiftData

/// Capture on the saving context's executor; never carry that context into UI
/// work. Only stable identity and Sendable persistent identifiers cross over.
nonisolated struct LibrarySaveEvent: Sendable {
    let contextID: ObjectIdentifier
    let containerID: ObjectIdentifier
    let inserted: [PersistentIdentifier]
    let updated: [PersistentIdentifier]
    let deleted: [PersistentIdentifier]
    let invalidated: [PersistentIdentifier]

    init?(_ notification: Notification) {
        guard let context = notification.object as? ModelContext else { return nil }
        contextID = ObjectIdentifier(context)
        containerID = ObjectIdentifier(context.container)
        func identifiers(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            if let ids = value as? Set<PersistentIdentifier> { return Array(ids) }
            return value as? [PersistentIdentifier] ?? []
        }
        inserted = identifiers(.insertedIdentifiers)
        updated = identifiers(.updatedIdentifiers)
        deleted = identifiers(.deletedIdentifiers)
        invalidated = identifiers(.invalidatedAllIdentifiers)
    }
}

nonisolated enum LibraryNotifications {
    static func modelSaves(center: NotificationCenter = .default) -> AnyPublisher<LibrarySaveEvent, Never> {
        center.publisher(for: ModelContext.didSave)
            .compactMap { LibrarySaveEvent($0) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    static func remoteChanges(center: NotificationCenter = .default) -> AnyPublisher<Void, Never> {
        center.publisher(for: .NSPersistentStoreRemoteChange)
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
