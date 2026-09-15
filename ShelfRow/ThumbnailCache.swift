//
//  ThumbnailCache.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Cocoa
import Foundation
import QuickLookThumbnailing

@globalActor
actor ThumbnailCacheActor {
    static let shared = ThumbnailCacheActor()
}

/// A highly-efficient, thread-safe asynchronous cache for cover images
/// with in-memory NSCache and disk file caching.
@ThumbnailCacheActor
final class ThumbnailCache {
    
    static let shared = ThumbnailCache()
    
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    
    /// Shared thumbnails disk-cache location (also used by the importer and
    /// the legacy thumbnail migration).
    nonisolated static var diskCacheDirectory: URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let appCache = paths[0].appendingPathComponent("jp.aromatics.ShelfRow", isDirectory: true)
        let thumbs = appCache.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true, attributes: nil)
        return thumbs
    }

    private let cacheDirectory: URL = ThumbnailCache.diskCacheDirectory
    
    private init() {
        memoryCache.countLimit = 200 // Limit to 200 images in memory to prevent RAM pressure
    }
    
    /// Resolves the file URL for an Item, handling security scoped bookmarks if available.
    private func resolveURL(for item: Item) -> (URL?, URL?) {
        // Item-level bookmark (drag & drop registration) takes precedence
        if let bookmark = item.bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
               resolved.startAccessingSecurityScopedResource() {
                return (resolved, resolved)
            }
        }

        guard let volume = item.volume else { return (nil, nil) }
        
        let volumeURL: URL
        var securityAnchorURL: URL? = nil
        
        // Handle security scoping
        if let bookmark = volume.bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                _ = resolved.startAccessingSecurityScopedResource()
                volumeURL = resolved
                securityAnchorURL = resolved
            } else {
                volumeURL = URL(fileURLWithPath: volume.lastKnownPath)
            }
        } else {
            volumeURL = URL(fileURLWithPath: volume.lastKnownPath)
        }
        
        let fileURL = volumeURL.appendingPathComponent(item.relativePath)
        return (fileURL, securityAnchorURL)
    }
    
    /// Scale down raw image data to a high-quality thumbnail using CGImageSource.
    /// This is extremely memory-efficient as it does not load the full-res image into RAM.
    private func createThumbnail(from data: Data, maxPixelSize: Int = 400) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: .zero)
    }
    
    /// Retrieves the cover image for an Item, loading from Memory -> Disk -> Source Extraction.
    func getCoverImage(for item: Item) -> NSImage? {
        let cacheKey = item.id.uuidString as NSString
        
        // 1. Memory Cache check (instant)
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }
        
        let localThumbnailURL = cacheDirectory.appendingPathComponent("\(item.id.uuidString).jpg")
        
        // 2. Disk Cache check
        if fileManager.fileExists(atPath: localThumbnailURL.path) {
            if let image = NSImage(contentsOf: localThumbnailURL) {
                memoryCache.setObject(image, forKey: cacheKey)
                return image
            }
        }
        
        // 2b. Legacy Stackroom Thumbnail Check (Instant reuse of pre-rendered assets)
        if let legacyID = item.legacyID {
            let legacyThumbPath = NSHomeDirectory() + "/Library/Application Support/Stackroom/Stackroom Library/\(legacyID)/thumbnail.jpg"
            if fileManager.fileExists(atPath: legacyThumbPath) {
                if let image = NSImage(contentsOfFile: legacyThumbPath) {
                    // Cache in memory
                    memoryCache.setObject(image, forKey: cacheKey)
                    // Copy to our disk cache so it becomes standalone
                    try? fileManager.copyItem(atPath: legacyThumbPath, toPath: localThumbnailURL.path)
                    return image
                }
            }
        }
        
        // 3. Source Extraction
        let (fileURL, securityAnchor) = resolveURL(for: item)
        defer {
            securityAnchor?.stopAccessingSecurityScopedResource()
        }
        
        guard let fileURL = fileURL, fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        // Try cover candidates in best-first order (sequence heuristic first).
        // Corrupt/truncated images ("IIOScanner seek reached EOF") fail to
        // decode, in which case we fall through to the next candidate.
        let pages = ItemFileAccess.listPages(at: fileURL)
        for candidate in CoverSelector.orderedCoverCandidates(from: pages) {
            guard let rawData = ItemFileAccess.loadPageData(bookURL: fileURL, page: candidate),
                  let thumbnail = createThumbnail(from: rawData) else {
                continue
            }

            // Write thumbnail to Disk Cache
            if let tiff = thumbnail.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
                try? jpegData.write(to: localThumbnailURL, options: .atomic)
            }

            // Put in Memory Cache
            memoryCache.setObject(thumbnail, forKey: cacheKey)
            return thumbnail
        }

        return nil
    }
    
    /// Sets a user-chosen cover image (from the 表紙を編集 dialog) for an item,
    /// overwriting the disk and memory caches. Returns the stored thumbnail.
    @discardableResult
    func setCustomCover(forItemID itemID: UUID, imageData: Data) -> NSImage? {
        guard let thumbnail = createThumbnail(from: imageData) else { return nil }

        let localThumbnailURL = cacheDirectory.appendingPathComponent("\(itemID.uuidString).jpg")
        if let tiff = thumbnail.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
            try? jpegData.write(to: localThumbnailURL, options: .atomic)
        }

        memoryCache.setObject(thumbnail, forKey: itemID.uuidString as NSString)
        return thumbnail
    }

    /// Clears both memory and disk cache.
    func clearCache() {
        memoryCache.removeAllObjects()
        if let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
