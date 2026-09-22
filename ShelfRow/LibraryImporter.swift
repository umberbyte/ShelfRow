//
//  LibraryImporter.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import SwiftData

/// An actor that handles the processing and importing of the legacy Stackroom XML Library plist
/// on a background thread to keep the main UI responsive.
@ModelActor
actor LibraryImporter {
    private struct ShelfIdentity: Hashable {
        let title: String
        let type: Int
    }

    private struct ImportedTextFields {
        let genre: String
        let relation: String
        let keywordA: String
        let keywordB: String
        let memo: String

        init(_ bookData: [String: Any]) {
            genre = bookData["Genre"] as? String ?? ""
            relation = bookData["Neta"] as? String ?? ""
            keywordA = bookData["Keyword A"] as? String ?? ""
            keywordB = bookData["Keyword B"] as? String ?? ""
            // Stackroom libraries in the wild use both spellings. The supplied
            // item 25192 uses "Memo", while older exports have used "memo".
            memo = bookData["Memo"] as? String
                ?? bookData["memo"] as? String
                ?? ""
        }
    }
    
    /// Cleans invalid XML 1.0 control characters from raw data.
    /// In XML 1.0, bytes in ranges 0x00-0x08, 0x0B-0x0C, and 0x0E-0x1F are strictly forbidden.
    private func cleanXMLData(_ data: Data) -> Data {
        var cleaned = Data(capacity: data.count)
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = data.count
            var i = 0
            while i < count {
                let byte = baseAddress[i]
                if (byte >= 0x00 && byte <= 0x08) ||
                    (byte == 0x0B || byte == 0x0C) ||
                    (byte >= 0x0E && byte <= 0x1F) {
                    // Skip invalid XML control bytes
                    i += 1
                    continue
                }
                cleaned.append(byte)
                i += 1
            }
        }
        return cleaned
    }
    
    private var cacheDirectory: URL {
        ThumbnailCache.diskCacheDirectory
    }
    
    /// Performs the library import on a background thread with real-time progress callbacks and Merge strategy.
    /// - Parameter legacyAssetsRoot: The legacy "Stackroom Library" folder containing
    ///   `[ID]/thumbnail.jpg` subfolders. Under the App Sandbox this must be a
    ///   user-selected (security-scoped) URL; pass nil to skip thumbnail migration.
    func importLibrary(
        from url: URL,
        legacyAssetsRoot: URL? = nil,
        progress: @Sendable @escaping @MainActor (_ processedBooks: Int, _ totalBooks: Int, _ processedPlaylists: Int, _ totalPlaylists: Int) -> Void
    ) async throws -> (booksCount: Int, playlistsCount: Int) {
        // Keep security-scoped access to the legacy assets folder for the whole import
        let scopedAssetsRoot = (legacyAssetsRoot?.startAccessingSecurityScopedResource() == true) ? legacyAssetsRoot : nil
        defer {
            scopedAssetsRoot?.stopAccessingSecurityScopedResource()
        }
        let thumbnailRootPath = legacyAssetsRoot?.path
            ?? NSHomeDirectory() + "/Library/Application Support/Stackroom/Stackroom Library"

        let rawData = try Data(contentsOf: url)
        let cleanedData = cleanXMLData(rawData)
        
        // Parse the cleaned plist data
        guard let plist = try PropertyListSerialization.propertyList(
            from: cleanedData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(domain: "LibraryImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid plist format"])
        }
        
        // Extract Books dictionary and Playlists array
        let booksDict = plist["Books"] as? [String: Any] ?? [:]
        let playlistsArray = plist["Playlists"] as? [[String: Any]] ?? []
        
        // Count totals
        let validBooks = booksDict.filter { $0.value is [String: Any] }
        let totalBooks = validBooks.count
        let totalPlaylists = playlistsArray.count
        
        // MainActor notification
        await MainActor.run {
            progress(0, totalBooks, 0, totalPlaylists)
        }
        
        // Fetch existing items to prevent duplicates (Merge Strategy)
        let existingItemsFetch = FetchDescriptor<Item>()
        let existingItems = try modelContext.fetch(existingItemsFetch)
        var existingItemsByLegacyID: [Int: Item] = [:]
        var existingItemsByPath: [String: Item] = [:]
        for item in existingItems {
            if let lid = item.legacyID {
                existingItemsByLegacyID[lid] = item
            }
            if !item.relativePath.isEmpty {
                existingItemsByPath[item.relativePath] = item
            }
        }
        
        var volumesCache: [String: Volume] = [:]
        var importedItemsCache: [Int: Item] = [:]
        
        // Set up volumes cache with existing volumes
        let existingVolumesFetch = FetchDescriptor<Volume>()
        let existingVolumes = try modelContext.fetch(existingVolumesFetch)
        for vol in existingVolumes {
            volumesCache[vol.lastKnownPath] = vol
        }
        
        // --- 1. Import Books ---
        var booksProcessed = 0
        var booksImported = 0
        
        for (_, val) in booksDict {
            // Ignore non-dictionary keys (such as ID version counter)
            guard let bookData = val as? [String: Any] else { continue }
            
            let legacyID = bookData["ID"] as? Int
            let explicitPath = bookData["Path"] as? String ?? ""
            let coverPath = bookData["Cover Image Path"] as? String ?? ""
            let filePath = explicitPath.isEmpty ? coverPath : explicitPath
            let (volumePath, volumeName, relativePath) = PathParser.split(filePath)
            let textFields = ImportedTextFields(bookData)
            
            // Check if item already exists (Merge Strategy)
            let existingItem: Item?
            if let lid = legacyID {
                // Stackroom assigns a monotonically increasing identity. The
                // same archive path may intentionally appear under a new ID, so
                // path matching must never collapse two identified records.
                existingItem = existingItemsByLegacyID[lid]
            } else if !relativePath.isEmpty, let item = existingItemsByPath[relativePath] {
                existingItem = item
            } else {
                existingItem = nil
            }
            
            if let existing = existingItem {
                // Preserve edits made in ShelfRow, while filling values the old
                // importer did not understand. Its former Neta -> memo mapping is
                // recognisable and can be repaired without guessing.
                let relationWasStoredAsMemo = !textFields.relation.isEmpty
                    && existing.relation.isEmpty
                    && existing.memo == textFields.relation
                if existing.genre.isEmpty { existing.genre = textFields.genre }
                if existing.relation.isEmpty { existing.relation = textFields.relation }
                if existing.keywordA.isEmpty { existing.keywordA = textFields.keywordA }
                if existing.keywordB.isEmpty { existing.keywordB = textFields.keywordB }
                if existing.memo.isEmpty || relationWasStoredAsMemo {
                    existing.memo = textFields.memo
                }

                if let lid = legacyID {
                    if existing.legacyID == nil { existing.legacyID = lid }
                    importedItemsCache[lid] = existing
                    existingItemsByLegacyID[lid] = existing

                    // Copy the legacy thumbnail for already-imported items too
                    // (e.g. re-import after granting folder access).
                    let legacyThumbPath = thumbnailRootPath + "/\(lid)/thumbnail.jpg"
                    let destURL = cacheDirectory.appendingPathComponent("\(existing.id.uuidString).jpg")
                    if !FileManager.default.fileExists(atPath: destURL.path),
                       FileManager.default.fileExists(atPath: legacyThumbPath) {
                        try? FileManager.default.copyItem(atPath: legacyThumbPath, toPath: destURL.path)
                    }
                }
                booksProcessed += 1
                if booksProcessed % 100 == 0 || booksProcessed == totalBooks {
                    let currentProcessed = booksProcessed
                    await MainActor.run {
                        progress(currentProcessed, totalBooks, 0, totalPlaylists)
                    }
                }
                continue
            }
            
            let title = bookData["Title"] as? String ?? "Unknown Title"
            let author = bookData["Author"] as? String ?? ""
            let rating = bookData["My Rate"] as? Int ?? 0
            let isUnread = bookData["Unseen"] as? Bool ?? true
            let pages = bookData["Pages"] as? Int ?? 0
            let bookType = bookData["Book Type"] as? Int ?? 0
            let fileType = bookData["File Type"] as? Int ?? 0
            let coverImageName = bookData["Cover Image Name"] as? String ?? ""
            let coverImagePath = bookData["Cover Image Path"] as? String ?? ""
            // Dates
            let addedDate = bookData["Date Added"] as? Date ?? Date()
            let lastReadDate = bookData["Play Date"] as? Date
            
            // Resolve or create Volume
            let volume: Volume
            if let cachedVolume = volumesCache[volumePath] {
                volume = cachedVolume
            } else {
                let newVolume = Volume(name: volumeName, lastKnownPath: volumePath)
                modelContext.insert(newVolume)
                volume = newVolume
                volumesCache[volumePath] = volume
            }
            
            // Create Item
            let item = Item(
                id: UUID(),
                legacyID: legacyID,
                volume: volume,
                relativePath: relativePath,
                title: title,
                author: author,
                rating: rating,
                isUnread: isUnread,
                genre: textFields.genre,
                relation: textFields.relation,
                keywordA: textFields.keywordA,
                keywordB: textFields.keywordB,
                memo: textFields.memo,
                coverImageName: coverImageName,
                coverImagePath: coverImagePath,
                addedDate: addedDate,
                lastReadDate: lastReadDate,
                pages: pages,
                bookType: bookType,
                fileType: fileType
            )
            
            modelContext.insert(item)
            if let lid = legacyID {
                importedItemsCache[lid] = item
                existingItemsByLegacyID[lid] = item
                
                // Bulk copy the thumbnail during import so the user can safely delete the old app directory immediately.
                let legacyThumbPath = thumbnailRootPath + "/\(lid)/thumbnail.jpg"
                if FileManager.default.fileExists(atPath: legacyThumbPath) {
                    let destURL = cacheDirectory.appendingPathComponent("\(item.id.uuidString).jpg")
                    try? FileManager.default.copyItem(atPath: legacyThumbPath, toPath: destURL.path)
                }
            }
            
            booksImported += 1
            booksProcessed += 1
            
            // Save in chunks to reduce memory pressure
            if booksImported % 1000 == 0 {
                try modelContext.save()
            }
            
            if booksProcessed % 100 == 0 || booksProcessed == totalBooks {
                let currentProcessed = booksProcessed
                await MainActor.run {
                    progress(currentProcessed, totalBooks, 0, totalPlaylists)
                }
            }
        }
        
        // Final save for books
        try modelContext.save()
        
        // Fetch existing shelves (Merge Strategy)
        let existingShelvesFetch = FetchDescriptor<Shelf>()
        let existingShelves = try modelContext.fetch(existingShelvesFetch)
        var shelvesByIdentity = Dictionary(
            existingShelves.map { (ShelfIdentity(title: $0.title, type: $0.type), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        
        // --- 2. Import Playlists/Shelves ---
        var playlistsProcessed = 0
        var playlistsImported = 0
        
        for pData in playlistsArray {
            let title = pData["Title"] as? String ?? "Unnamed Shelf"
            let icon = pData["Icon"] as? Int ?? 0
            let type = pData["Type"] as? Int ?? 0
            let identity = ShelfIdentity(title: title, type: type)
            
            playlistsProcessed += 1
            
            // An updated XML can add books to an existing static shelf. Merge
            // membership by legacy ID and deliberately keep local/removed XML
            // members: repeat import is additive and never deletes data.
            if let existingShelf = shelvesByIdentity[identity] {
                if type == 0, let itemIDs = pData["Items"] as? [Int] {
                    merge(
                        itemIDs: itemIDs,
                        into: existingShelf,
                        importedItems: importedItemsCache,
                        existingItems: existingItemsByLegacyID
                    )
                }
                let currentProcessed = playlistsProcessed
                await MainActor.run {
                    progress(totalBooks, totalBooks, currentProcessed, totalPlaylists)
                }
                continue
            }
            
            // Convert Smart conditions to JSON
            var conditionsJson: String? = nil
            if type == 1, let conditions = pData["Conditions"] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: conditions, options: []),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    conditionsJson = jsonString
                }
            }
            
            let sortInfo = pData["Sort"] as? [String: Any]
            let sortAscending = sortInfo?["ascending"] as? Bool ?? true
            let sortKey = sortInfo?["key"] as? String ?? "title"
            
            // Create Shelf
            let shelf = Shelf(
                title: title,
                icon: icon,
                type: type,
                sortOrder: playlistsProcessed * 10,
                sortAscending: sortAscending,
                sortKey: sortKey,
                smartConditionsJson: conditionsJson
            )
            modelContext.insert(shelf)
            shelvesByIdentity[identity] = shelf
            
            // Map legacy IDs to items for Static Shelves (Type 0)
            if type == 0, let itemIDs = pData["Items"] as? [Int] {
                merge(
                    itemIDs: itemIDs,
                    into: shelf,
                    importedItems: importedItemsCache,
                    existingItems: existingItemsByLegacyID
                )
            }
            
            playlistsImported += 1

            let currentProcessed = playlistsProcessed
            await MainActor.run {
                progress(totalBooks, totalBooks, currentProcessed, totalPlaylists)
            }
        }
        
        // Save playlists
        try modelContext.save()
        
        return (booksImported, playlistsImported)
    }

    private func merge(
        itemIDs: [Int],
        into shelf: Shelf,
        importedItems: [Int: Item],
        existingItems: [Int: Item]
    ) {
        var items = shelf.items ?? []
        var presentIDs = Set(items.map(\.id))
        for legacyID in itemIDs {
            guard let item = importedItems[legacyID] ?? existingItems[legacyID],
                  presentIDs.insert(item.id).inserted else { continue }
            items.append(item)
        }
        shelf.items = items
    }
}
