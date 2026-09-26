//
//  LibraryRegistrar.swift
//  ShelfRow
//

import Foundation
import OSLog
import SwiftData

/// What kind of thing was handed to the library, which decides the file type
/// recorded and whether the pages are worth counting.
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

/// Puts a file into the library: the work a drag and drop does, with nothing of
/// the drag in it.
///
/// It lives apart from the view because a second caller wants the same thing to
/// happen — the command line tool adds files without a window in sight — and two
/// copies of "what registering a book means" would drift the first time one of
/// them learned something.
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
        /// Whether the pages are worth counting now, and what to do with the answer.
        let shouldCountPages: Bool
        let shouldApplyAutoBookType: Bool
    }

    let context: ModelContext
    let vault: BookmarkVault
    let settings: Settings

    /// Whether this is something the library takes, and as what.
    func kind(for url: URL, isDirectory: Bool) -> DroppedFileKind? {
        if isDirectory { return .folder }

        let ext = url.pathExtension.lowercased()
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
    @discardableResult
    func register(
        url: URL,
        kind: DroppedFileKind,
        targetShelfID: UUID?,
        deferBookmarkSave: Bool = false,
        itemsByPath: inout [String: Item],
        volumesByPath: inout [String: Volume]
    ) -> Outcome {
        let (volumePath, volumeName, relativePath) = PathParser.split(url.path)

        // Already here: keep the one book and take the chance to renew its access,
        // which is the other half of what re-dropping a file is for.
        if let existing = itemsByPath[relativePath] {
            if let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                vault.setBookmark(refreshed, for: existing.id, saveImmediately: !deferBookmarkSave)
            }
            addToStaticShelf(existing, shelfID: targetShelfID)
            return Outcome(
                itemID: existing.id,
                isNew: false,
                shouldCountPages: existing.pages == 0 && kind.shouldUsePageCountForBookType,
                shouldApplyAutoBookType: false
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

        // Whoever called us can reach the file right now; a bookmark is how that
        // survives to the next launch.
        let itemBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

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
        if let itemBookmark {
            vault.setBookmark(itemBookmark, for: itemID, saveImmediately: !deferBookmarkSave)
        }
        addToStaticShelf(item, shelfID: targetShelfID)

        return Outcome(
            itemID: itemID,
            isNew: true,
            shouldCountPages: kind.shouldUsePageCountForBookType,
            shouldApplyAutoBookType: parsedBookType == nil
        )
    }

    /// Records the page count, and the type it implies when the file name did
    /// not already say.
    func applyPageCount(_ pages: Int, to itemID: UUID, applyingAutoBookType: Bool) {
        guard let item = try? context.fetch(
            FetchDescriptor<Item>(predicate: #Predicate { $0.id == itemID })
        ).first else { return }

        item.pages = pages
        if applyingAutoBookType, let autoBookType = BookTypeAutoClassifier.classify(pageCount: pages) {
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
