//
//  ThumbnailCache.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Cocoa
import Foundation
import ImageIO
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
    private var missingCoverKeys: Set<String> = []
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
        guard CoverSelector.imageDataLooksComplete(data) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
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

    /// Loads an already-cached thumbnail eagerly. NSImage(contentsOf:) can defer
    /// decoding until drawing, which makes row selection feel like the cache miss
    /// happened on the main thread.
    private func loadCachedThumbnail(at url: URL) -> NSImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    /// Retrieves the cover image for an Item, loading from Memory -> Disk -> Source Extraction.
    func getCoverImage(for item: Item) async -> NSImage? {
        let cacheKeyString = item.id.uuidString
        let cacheKey = cacheKeyString as NSString

        // 1. Memory Cache check (instant)
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        let localThumbnailURL = cacheDirectory.appendingPathComponent("\(item.id.uuidString).jpg")

        // 2. Disk Cache check
        if fileManager.fileExists(atPath: localThumbnailURL.path) {
            if let image = loadCachedThumbnail(at: localThumbnailURL) {
                memoryCache.setObject(image, forKey: cacheKey)
                return image
            }
        }

        // 2b. Legacy Stackroom Thumbnail Check (Instant reuse of pre-rendered assets)
        if let legacyID = item.legacyID {
            let legacyThumbPath = NSHomeDirectory() + "/Library/Application Support/Stackroom/Stackroom Library/\(legacyID)/thumbnail.jpg"
            if fileManager.fileExists(atPath: legacyThumbPath) {
                let legacyThumbURL = URL(fileURLWithPath: legacyThumbPath)
                if let image = loadCachedThumbnail(at: legacyThumbURL) {
                    memoryCache.setObject(image, forKey: cacheKey)
                    try? fileManager.copyItem(atPath: legacyThumbPath, toPath: localThumbnailURL.path)
                    return image
                }
            }
        }

        if missingCoverKeys.contains(cacheKeyString) {
            return nil
        }

        // 3. Source Extraction
        // Read SwiftData model values here on the actor (safe), then hand off raw
        // values to DispatchQueue.global so that bookmark resolution, security-scope
        // setup, fileExists, and ZIP extraction — all of which can be slow on
        // network volumes (SMB/AFP) — never block the cooperative thread pool.
        let itemBookmark = item.bookmarkData
        let volumeBookmark = item.volume?.bookmarkData
        let volumeLastKnownPath = item.volume?.lastKnownPath ?? ""
        let relativePath = item.relativePath

        let coverData: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var resolvedURL: URL? = nil
                var securityAnchor: URL? = nil

                // Item-level bookmark (drag & drop) takes precedence.
                if let bookmark = itemBookmark {
                    var isStale = false
                    if let resolved = try? URL(resolvingBookmarkData: bookmark,
                                               options: .withSecurityScope,
                                               relativeTo: nil,
                                               bookmarkDataIsStale: &isStale),
                       resolved.startAccessingSecurityScopedResource() {
                        resolvedURL = resolved
                        securityAnchor = resolved
                    }
                }

                // Volume-level bookmark + relative path.
                if resolvedURL == nil {
                    var volumeURL = URL(fileURLWithPath: volumeLastKnownPath)
                    if let bookmark = volumeBookmark {
                        var isStale = false
                        if let resolved = try? URL(resolvingBookmarkData: bookmark,
                                                   options: .withSecurityScope,
                                                   relativeTo: nil,
                                                   bookmarkDataIsStale: &isStale) {
                            _ = resolved.startAccessingSecurityScopedResource()
                            securityAnchor = resolved
                            volumeURL = resolved
                        }
                    }
                    resolvedURL = volumeURL.appendingPathComponent(relativePath)
                }

                defer { securityAnchor?.stopAccessingSecurityScopedResource() }

                guard let fileURL = resolvedURL,
                      FileManager.default.fileExists(atPath: fileURL.path) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CoverSelector.preferredCoverData(bookURL: fileURL))
            }
        }

        guard let coverData,
              let thumbnail = createThumbnail(from: coverData) else {
            missingCoverKeys.insert(cacheKeyString)
            return nil
        }

        // Write thumbnail to Disk Cache
        if let tiff = thumbnail.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
            try? jpegData.write(to: localThumbnailURL, options: .atomic)
        }

        // Put in Memory Cache
        memoryCache.setObject(thumbnail, forKey: cacheKey)
        missingCoverKeys.remove(cacheKeyString)
        return thumbnail
    }

    func invalidateFailure(forItemID itemID: UUID?) {
        if let itemID {
            missingCoverKeys.remove(itemID.uuidString)
        } else {
            missingCoverKeys.removeAll()
        }
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
        missingCoverKeys.remove(itemID.uuidString)
        return thumbnail
    }

    /// Clears both memory and disk cache.
    func clearCache() {
        memoryCache.removeAllObjects()
        missingCoverKeys.removeAll()
        if let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
