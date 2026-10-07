//
//  LibraryRegistration.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// What kind of thing is being taken in, which decides the file type recorded
/// and whether its pages are worth counting.
enum DroppedFileKind: Equatable, Sendable {
    case folder
    case pageCountedArchive
    case helperFile

    var shouldUsePageCountForBookType: Bool {
        switch self {
        case .folder, .pageCountedArchive: return true
        case .helperFile: return false
        }
    }

    var fileType: Int {
        switch self {
        case .folder: return 1
        case .pageCountedArchive: return 2
        case .helperFile: return 0
        }
    }
}

/// Puts a file into the library.
///
/// The stage between `DroppedFilePreflight`, which has already asked the share
/// everything that needs asking, and the store. It touches no files of its own:
/// whether the file is there, and the bookmark that keeps access to it, arrive
/// in the fact it is handed. That is what lets the same registration serve a
/// drop and a command line — one is a window's worth of providers, the other a
/// path typed in a terminal, and by this point neither is distinguishable.
@MainActor
struct LibraryRegistrar {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "Registrar")

    /// The parts of the person's settings that change what registering does.
    struct Settings: Sendable, Equatable {
        var renameFormat: String
        /// The six type names, in the order their indexes are stored in.
        var typeNames: [String]
        /// Extensions the helper settings claim, lower-cased and without dots.
        var helperExtensions: Set<String>

        static func fromDefaults(_ defaults: UserDefaults = .standard) -> Settings {
            let names = [
                ("typeNameThickBook", "厚い本"),
                ("typeNameThinBook", "薄い本"),
                ("typeNamePartBook", "本の一部"),
                ("typeNameImageSet", "画像セット"),
                ("typeNameText", "テキスト"),
                ("typeNameMovie", "ムービー")
            ].map { key, fallback in
                customName(defaults.string(forKey: key) ?? "", default: fallback)
            }

            let list = defaults.string(forKey: "helperExtensionsList") ?? "mov, avi, mpg\nrar, zip, 7z"
            return Settings(
                renameFormat: defaults.string(forKey: "customRenameFormat") ?? "[@author] @title",
                typeNames: names,
                helperExtensions: Self.extensions(in: list)
            )
        }

        /// The helper list is lines of comma-separated extensions, written by
        /// hand, so it arrives with dots, spaces and mixed case in it.
        static func extensions(in list: String) -> Set<String> {
            Set(
                list.components(separatedBy: CharacterSet(charactersIn: "\n,"))
                    .map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                            .lowercased()
                    }
                    .filter { !$0.isEmpty }
            )
        }
    }

    /// What became of one file.
    struct Outcome: Sendable {
        let itemID: UUID
        /// False when the book was already in the library and was only refreshed.
        let isNew: Bool
        /// Set when the pages still have to be counted, which happens after the
        /// books are visible rather than while the person waits.
        let pageCount: DroppedFilePageCountRequest?
    }

    let context: ModelContext
    let vault: BookmarkVault
    let settings: Settings

    /// Whether this is something the library takes, and as what.
    func kind(for fact: DroppedFileFact) -> DroppedFileKind? {
        guard fact.exists else { return nil }
        if fact.isDirectory { return .folder }

        let ext = fact.url.pathExtension.lowercased()
        if ["zip", "rar", "7z"].contains(ext), ext == "zip" || settings.helperExtensions.contains(ext) {
            return .pageCountedArchive
        }
        if settings.helperExtensions.contains(ext) {
            return .helperFile
        }
        return nil
    }

    /// Registers one file, or refreshes the book already standing for it.
    ///
    /// The two dictionaries are carried by the caller so a run over many files
    /// does not re-fetch the library for each one; they are updated as it goes.
    func register(
        fact: DroppedFileFact,
        kind: DroppedFileKind,
        targetShelfID: UUID?,
        deferBookmarkSave: Bool = true,
        itemsByPath: inout [String: Item],
        volumesByPath: inout [String: Volume]
    ) -> Outcome {
        let url = fact.url
        let (volumePath, volumeName, relativePath) = PathParser.split(url.path)

        // Already here: keep the one book and take the chance to renew its
        // access, which is the other half of what re-dropping a file is for.
        if let existing = itemsByPath[relativePath] {
            if let bookmark = fact.bookmarkData {
                vault.setBookmark(bookmark, for: existing.id, saveImmediately: !deferBookmarkSave)
            }
            addToStaticShelf(existing, shelfID: targetShelfID)
            let needsPages = existing.pages == 0 && kind.shouldUsePageCountForBookType
            return Outcome(
                itemID: existing.id,
                isNew: false,
                pageCount: needsPages
                    ? DroppedFilePageCountRequest(itemID: existing.id, url: url, shouldApplyAutoBookType: false)
                    : nil
            )
        }

        let volume: Volume
        if let existing = volumesByPath[volumePath] {
            volume = existing
        } else {
            let fresh = Volume(name: volumeName, lastKnownPath: volumePath)
            context.insert(fresh)
            volumesByPath[volumePath] = fresh
            volume = fresh
        }

        let parsed = FileNameParser.parse(fileName: url.lastPathComponent, format: settings.renameFormat)
        let title = parsed.title.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.title
        let parsedBookType = bookTypeIndex(for: parsed.type)

        let itemID = UUID()
        let item = Item(
            id: itemID,
            volume: volume,
            relativePath: relativePath,
            title: title,
            author: parsed.author,
            genre: parsed.genre,
            relation: parsed.relation,
            keywordA: parsed.keywordA,
            keywordB: parsed.keywordB,
            pages: 0,
            bookType: parsedBookType ?? (kind == .helperFile ? 5 : 0),
            fileType: kind.fileType
        )

        context.insert(item)
        itemsByPath[relativePath] = item
        if let bookmark = fact.bookmarkData {
            vault.setBookmark(bookmark, for: itemID, saveImmediately: !deferBookmarkSave)
        }
        addToStaticShelf(item, shelfID: targetShelfID)

        return Outcome(
            itemID: itemID,
            isNew: true,
            pageCount: kind.shouldUsePageCountForBookType
                ? DroppedFilePageCountRequest(
                    itemID: itemID,
                    url: url,
                    shouldApplyAutoBookType: parsedBookType == nil
                )
                : nil
        )
    }

    /// Records a page count that has come back, and the type it implies when the
    /// file name did not already say.
    func apply(_ update: DroppedFilePageCountUpdate) {
        let itemID = update.itemID
        guard let item = try? context.fetch(
            FetchDescriptor<Item>(predicate: #Predicate { $0.id == itemID })
        ).first else { return }

        item.pages = update.pageCount
        if update.shouldApplyAutoBookType,
           let autoBookType = BookTypeAutoClassifier.classify(pageCount: update.pageCount) {
            item.bookType = autoBookType
        }
    }

    /// Ordinary shelves are a list someone keeps; smart shelves are a question
    /// the library answers, so nothing is put into them by hand.
    private func addToStaticShelf(_ item: Item, shelfID: UUID?) {
        guard let shelfID,
              let shelf = try? context.fetch(
                FetchDescriptor<Shelf>(predicate: #Predicate { $0.id == shelfID })
              ).first,
              shelf.type == 0 else {
            return
        }

        var items = shelf.items ?? []
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        shelf.items = items
    }

    /// The index of the type a file name named, if it named one the person uses.
    func bookTypeIndex(for parsedType: String) -> Int? {
        let trimmed = parsedType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return settings.typeNames.firstIndex { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }
}
