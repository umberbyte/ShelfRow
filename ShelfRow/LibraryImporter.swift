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
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let appCache = paths[0].appendingPathComponent("jp.aromatics.ShelfRow", isDirectory: true)
        let thumbs = appCache.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true, attributes: nil)
        return thumbs
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
            existingItemsByPath[item.relativePath] = item
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
            let filePath = bookData["Path"] as? String ?? ""
            let (volumePath, volumeName, relativePath) = PathParser.split(filePath)
            
            // Check if item already exists (Merge Strategy)
            let existingItem: Item?
            if let lid = legacyID, let item = existingItemsByLegacyID[lid] {
                existingItem = item
            } else if let item = existingItemsByPath[relativePath] {
                existingItem = item
            } else {
                existingItem = nil
            }
            
            if let existing = existingItem {
                // Skip importing but map in cache for playlist relationship matching
                if let lid = legacyID {
                    importedItemsCache[lid] = existing

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
            let keywordA = bookData["Keyword A"] as? String ?? ""
            let keywordB = bookData["Keyword B"] as? String ?? ""
            let memo = bookData["Neta"] as? String ?? "" // "Neta" maps to Memo
            
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
                genre: "", 
                relation: "",
                keywordA: keywordA,
                keywordB: keywordB,
                memo: memo,
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
        let existingShelvesByTitleAndType = Set(existingShelves.map { "\($0.title)_\($0.type)" })
        
        // --- 2. Import Playlists/Shelves ---
        var playlistsProcessed = 0
        var playlistsImported = 0
        
        for pData in playlistsArray {
            let title = pData["Title"] as? String ?? "Unnamed Shelf"
            let icon = pData["Icon"] as? Int ?? 0
            let type = pData["Type"] as? Int ?? 0
            
            playlistsProcessed += 1
            
            // Skip duplicate shelves
            if existingShelvesByTitleAndType.contains("\(title)_\(type)") {
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
            
            // Map legacy IDs to items for Static Shelves (Type 0)
            if type == 0, let itemIDs = pData["Items"] as? [Int] {
                var associatedItems: [Item] = []
                for id in itemIDs {
                    if let item = importedItemsCache[id] {
                        associatedItems.append(item)
                    }
                }
                shelf.items = associatedItems
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
}
