//
//  LocalStore.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// A security-scoped bookmark for one `Item` or `Volume`, held in the
/// device-local store so it never reaches iCloud.
///
/// Bookmarks are minted against the machine that resolved the file and mean
/// nothing anywhere else. Syncing them would have each device overwrite the
/// last one's bookmark with a copy it cannot resolve, so the shared library
/// carries only the path and this table carries the access.
@Model
final class LocalBookmark {
    /// `Item.id` or `Volume.id`.
    var targetID: UUID = UUID()
    var data: Data = Data()
    var updatedAt: Date = Date()

    init(targetID: UUID, data: Data, updatedAt: Date = Date()) {
        self.targetID = targetID
        self.data = data
        self.updatedAt = updatedAt
    }
}

/// The app's bookmarks, kept in memory and written through to the local store.
///
/// Resolving a file happens while drawing rows, so the read has to be a
/// synchronous dictionary lookup rather than a fetch per item.
@MainActor
final class BookmarkVault {
    static let shared = BookmarkVault()

    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "Bookmarks")
    private static let adoptionDefaultsKey = "didMoveBookmarksToLocalStore"

    private var data: [UUID: Data] = [:]
    private var rows: [UUID: LocalBookmark] = [:]
    private var context: ModelContext?

    private init() {}

    /// Points the vault at a container's local store and loads every bookmark.
    /// Called once at startup and again after the library store is reopened in a
    /// different mode, since that replaces the context these rows belong to.
    /// `adoptBookmarksStoredOnModels` is the caller's next step.
    func attach(to container: ModelContainer) {
        let context = container.mainContext
        self.context = context
        data.removeAll()
        rows.removeAll()

        do {
            for row in try context.fetch(FetchDescriptor<LocalBookmark>()) {
                rows[row.targetID] = row
                data[row.targetID] = row.data
            }
            Self.logger.info("Loaded \(self.data.count, privacy: .public) bookmarks from the local store")
        } catch {
            Self.logger.error("Could not read local bookmarks: \(error.localizedDescription, privacy: .public)")
        }
    }

    func bookmark(for targetID: UUID) -> Data? {
        data[targetID]
    }

    func hasBookmark(for targetID: UUID) -> Bool {
        data[targetID] != nil
    }

    /// Stores (or with `nil`, removes) the bookmark for one item or volume.
    func setBookmark(_ bookmark: Data?, for targetID: UUID) {
        guard let context else { return }

        guard let bookmark else {
            data[targetID] = nil
            if let row = rows.removeValue(forKey: targetID) {
                context.delete(row)
            }
            save(context)
            return
        }

        data[targetID] = bookmark
        if let row = rows[targetID] {
            row.data = bookmark
            row.updatedAt = Date()
        } else {
            let row = LocalBookmark(targetID: targetID, data: bookmark)
            context.insert(row)
            rows[targetID] = row
        }
        save(context)
    }

    /// Moves bookmarks off `Item.bookmarkData` / `Volume.bookmarkData`, which is
    /// where builds before the local store kept them. Runs once per device: after
    /// it, those properties stay empty and the shared library has nothing
    /// device-specific left to sync.
    func adoptBookmarksStoredOnModels(defaults: UserDefaults = .standard) {
        guard let context, !defaults.bool(forKey: Self.adoptionDefaultsKey) else { return }

        var adopted = 0
        do {
            for volume in try context.fetch(FetchDescriptor<Volume>()) {
                guard let bookmark = volume.bookmarkData else { continue }
                setBookmark(bookmark, for: volume.id)
                volume.bookmarkData = nil
                adopted += 1
            }
            for item in try context.fetch(FetchDescriptor<Item>()) {
                guard let bookmark = item.bookmarkData else { continue }
                setBookmark(bookmark, for: item.id)
                item.bookmarkData = nil
                adopted += 1
            }
            try context.save()
            defaults.set(true, forKey: Self.adoptionDefaultsKey)
            Self.logger.info("Moved \(adopted, privacy: .public) bookmarks into the local store")
        } catch {
            // Leaving the flag unset retries on the next launch. The bookmarks are
            // still on the models until then, so nothing is lost by failing here.
            Self.logger.error("Could not move bookmarks into the local store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            Self.logger.error("Could not save a bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }
}
