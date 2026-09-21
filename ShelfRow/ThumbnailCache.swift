//
//  ThumbnailCache.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Cocoa
import Foundation
import ImageIO
import OSLog
import QuickLookThumbnailing

nonisolated private let thumbnailLogger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "Thumbnails")

@globalActor
actor ThumbnailCacheActor {
    static let shared = ThumbnailCacheActor()
}

/// Everything the loader needs from an `Item`, captured as plain values so cover
/// loading never reaches back into the SwiftData model from another actor.
struct ThumbnailRequest: Sendable, Hashable {
    let itemID: UUID
    let legacyID: Int?
    let itemBookmark: Data?
    let volumeBookmark: Data?
    let volumeLastKnownPath: String
    let relativePath: String
    @MainActor
    init(item: Item) {
        let vault = BookmarkVault.shared
        self.itemID = item.id
        self.legacyID = item.legacyID
        self.itemBookmark = vault.bookmark(for: item.id)
        self.volumeBookmark = item.volume.flatMap { vault.bookmark(for: $0.id) }
        self.volumeLastKnownPath = item.volume?.lastKnownPath ?? ""
        self.relativePath = item.relativePath
    }
}

/// Picks which covers to warm up around the one currently on screen.
enum CoverPrefetchWindow {
    /// Indices surrounding `index`, nearest first and forward before backward,
    /// clamped to `0..<count`. `index` itself is excluded: the visible cover is
    /// requested by the view that shows it.
    static func indices(around index: Int, count: Int, radius: Int) -> [Int] {
        guard count > 0, radius > 0, index >= 0, index < count else { return [] }

        var result: [Int] = []
        for distance in 1...radius {
            let after = index + distance
            if after < count { result.append(after) }
            let before = index - distance
            if before >= 0 { result.append(before) }
        }
        return result
    }
}

/// `NSCache` is already thread-safe, so the memory tier lives outside the actor:
/// the UI can check it synchronously and draw an image it has decoded before in
/// the same frame, instead of showing a placeholder for one actor hop.
nonisolated private final class ThumbnailMemoryStore: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int, totalCostLimit: Int) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.decodedByteCount(of: image))
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func remove(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    /// Covers vary in size, so the byte budget is what actually bounds RAM; the
    /// count limit is only a backstop.
    private static func decodedByteCount(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 1 }
        return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
    }
}

/// Sized for browsing a large library: enough covers to keep the rows around a
/// long scroll resident, bounded by a byte budget rather than a count so the
/// ceiling holds whatever their dimensions are.
nonisolated private let thumbnailMemoryStore = ThumbnailMemoryStore(
    countLimit: 1500,
    totalCostLimit: 320 * 1024 * 1024
)

/// Resolved once: the disk tier runs outside the actor and would otherwise
/// re-create the directory on every read.
nonisolated private let thumbnailCacheDirectory: URL = ThumbnailCache.diskCacheDirectory

/// Reading an already-rendered thumbnail gets its own lane. A small number of
/// prefetch reads may run together, while the foreground cover can start without
/// waiting behind all of them.
nonisolated private let thumbnailReadQueue = DispatchQueue(
    label: "\(ThumbnailCache.appIdentifier).thumbnail-read",
    qos: .userInitiated,
    attributes: .concurrent
)

/// Archive and NAS reads are blocking. Keeping them off Swift's cooperative
/// executor prevents a slow share from taking away a worker needed by UI tasks.
nonisolated private let thumbnailExtractionQueue = DispatchQueue(
    label: "\(ThumbnailCache.appIdentifier).thumbnail-extraction",
    qos: .utility,
    attributes: .concurrent
)

/// Lets work already queued on a GCD lane notice that whoever asked for it has
/// gone away. Dispatch work items cannot be cancelled once enqueued, so the
/// block checks this instead.
nonisolated private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A highly-efficient, thread-safe asynchronous cache for cover images
/// with in-memory NSCache and disk file caching.
@ThumbnailCacheActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private var missingCoverKeys: Set<String> = []
    private var inFlightLoads: [UUID: Task<NSImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    /// This app's own identifier, used to namespace its Caches subdirectory and its
    /// log subsystems. Not "jp.aromatics" — that identifier belongs to Stackroom's
    /// author, copied in by mistake, never this app's.
    nonisolated static let appIdentifier = Bundle.main.bundleIdentifier ?? "com.eureka.ShelfRow"

    /// Shared thumbnails disk-cache location (also used by the importer and
    /// the legacy thumbnail migration).
    nonisolated static let diskCacheDirectory: URL = {
        let appCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appIdentifier, isDirectory: true)
        let thumbs = appCache.appendingPathComponent("Thumbnails", isDirectory: true)

        migrateFromMisnamedCacheDirectoryIfNeeded(to: thumbs)

        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true, attributes: nil)
        return thumbs
    }()

    /// One-time move from the "jp.aromatics.ShelfRow" Caches folder builds before
    /// this fix used, so existing thumbnails carry forward instead of silently
    /// starting over — bulk generation's per-book completion record lives in
    /// SwiftData, not here, and would otherwise believe everything is already
    /// generated while every thumbnail file had effectively vanished.
    nonisolated private static func migrateFromMisnamedCacheDirectoryIfNeeded(to thumbs: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: thumbs.path) else { return }

        let legacyThumbs = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.aromatics.ShelfRow", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyThumbs.path) else { return }

        try? fileManager.createDirectory(
            at: thumbs.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: legacyThumbs, to: thumbs)
    }

    private init() {}

    /// Synchronous peek at the memory tier, for callers that can draw the cover
    /// immediately when it has already been decoded.
    nonisolated static func cachedImage(forItemID itemID: UUID) -> NSImage? {
        thumbnailMemoryStore.image(forKey: itemID.uuidString)
    }

    /// Memory -> disk -> legacy Stackroom thumbnail, stopping short of extracting
    /// the cover from the archive.
    ///
    /// Deliberately outside the actor: decoding a thumbnail costs real CPU, and on
    /// the actor this read would queue behind whatever prefetching is decoding and
    /// re-encoding — which is exactly when the cover on screen needs it.
    nonisolated static func renderedCoverImage(for request: ThumbnailRequest) async -> NSImage? {
        if let cached = cachedImage(forItemID: request.itemID) {
            return cached
        }

        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                thumbnailReadQueue.async {
                    // The cursor has already moved past this row. Decoding it now
                    // would only delay the row that is actually on screen, which is
                    // waiting behind it on this lane.
                    guard !flag.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: renderedThumbnail(for: request))
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// The tiers that only read already-rendered thumbnails: the local disk cache
    /// and the Stackroom library. Both are local files, so this keeps up with the
    /// cursor as long as it is not serialized behind heavier work.
    nonisolated static func renderedThumbnail(for request: ThumbnailRequest) -> NSImage? {
        let cacheKeyString = request.itemID.uuidString
        if let cached = thumbnailMemoryStore.image(forKey: cacheKeyString) { return cached }
        let fileManager = FileManager.default
        let localThumbnailURL = thumbnailCacheDirectory.appendingPathComponent("\(cacheKeyString).jpg")

        // Disk Cache check
        if fileManager.fileExists(atPath: localThumbnailURL.path) {
            if let image = loadCachedThumbnail(at: localThumbnailURL) {
                thumbnailMemoryStore.store(image, forKey: cacheKeyString)
                return image
            }
        }

        // Legacy Stackroom Thumbnail Check (Instant reuse of pre-rendered assets)
        if let legacyID = request.legacyID {
            let legacyThumbPath = NSHomeDirectory() + "/Library/Application Support/Stackroom/Stackroom Library/\(legacyID)/thumbnail.jpg"
            if fileManager.fileExists(atPath: legacyThumbPath) {
                let legacyThumbURL = URL(fileURLWithPath: legacyThumbPath)
                if let image = loadCachedThumbnail(at: legacyThumbURL) {
                    thumbnailMemoryStore.store(image, forKey: cacheKeyString)
                    try? fileManager.copyItem(atPath: legacyThumbPath, toPath: localThumbnailURL.path)
                    return image
                }
            }
        }

        return nil
    }

    /// Resolves the item's file, picks its cover, renders the thumbnail and writes
    /// it to the disk cache. This is the expensive path — bookmark resolution, a
    /// read over the volume, and a decode plus re-encode — so it is nonisolated:
    /// callers run it on a background queue, and several can run at once.
    nonisolated static func extractThumbnailToDiskCache(
        for request: ThumbnailRequest
    ) -> (image: NSImage?, fileWasReachable: Bool) {
        // Another Mac may have done this already. Copying its answer off the
        // share costs one small read; opening the archive costs a decompression
        // and a pass over the pages to pick a cover. The folder's index says
        // which covers are there, so a book it does not list costs nothing to
        // rule out — over a share, being told no is as slow as being told yes,
        // and a bulk run would ask twenty thousand times.
        if ThumbnailDistribution.holdsCover(forItemID: request.itemID),
           let fromDistribution = thumbnailFromDistributionFolder(forItemID: request.itemID) {
            return (fromDistribution, true)
        }

        var resolvedURL: URL? = nil
        var securityAnchor: URL? = nil

        // Item-level bookmark (drag & drop) takes precedence.
        if let bookmark = request.itemBookmark {
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
            var volumeURL = URL(fileURLWithPath: request.volumeLastKnownPath)
            if let bookmark = request.volumeBookmark {
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
            resolvedURL = volumeURL.appendingPathComponent(request.relativePath)
        }

        defer { securityAnchor?.stopAccessingSecurityScopedResource() }

        // Unreachable right now (volume unmounted, file moved) is a different
        // answer from reachable-but-nothing-inside: only the second one will still
        // be true the next time the library is scanned.
        guard let fileURL = resolvedURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return (nil, false)
        }

        guard let coverData = CoverSelector.preferredCoverData(bookURL: fileURL),
              let thumbnail = createThumbnail(from: coverData) else {
            return (nil, true)
        }

        // Only a thumbnail that reached the disk counts as generated: reporting
        // success for one that did not leaves a book with no file and a record
        // saying it has one.
        let localThumbnailURL = thumbnailCacheDirectory
            .appendingPathComponent("\(request.itemID.uuidString).jpg")
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpegData = bitmap.representation(using: .jpeg, properties: [:]) else {
            thumbnailLogger.error("Could not encode a thumbnail for \(request.itemID.uuidString, privacy: .public)")
            return (nil, true)
        }

        do {
            try jpegData.write(to: localThumbnailURL, options: .atomic)
        } catch {
            thumbnailLogger.error("""
                Could not write the thumbnail for \(request.itemID.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return (nil, true)
        }

        return (thumbnail, true)
    }

    /// Bridges blocking archive/NAS work onto the dedicated I/O queue while the
    /// caller remains in structured concurrency.
    nonisolated private static func extractThumbnailInBackground(
        for request: ThumbnailRequest
    ) async -> (image: NSImage?, fileWasReachable: Bool) {
        await withCheckedContinuation { continuation in
            thumbnailExtractionQueue.async {
                continuation.resume(returning: extractThumbnailToDiskCache(for: request))
            }
        }
    }

    /// Copies one cover out of the NAS distribution folder, if it holds it.
    ///
    /// Answers nil for every reason — no folder chosen, share not mounted, that
    /// book not there yet — because all of them mean the same thing here: carry
    /// on and generate it. The bookkeeping row is not written from here; the next
    /// distribution pass adopts the file it finds (`adoptLocalFiles`), which keeps
    /// this path free of the store.
    nonisolated private static func thumbnailFromDistributionFolder(forItemID itemID: UUID) -> NSImage? {
        guard let root = ThumbnailDistribution.currentRoot else { return nil }
        let localFile = thumbnailCacheDirectory.appendingPathComponent("\(itemID.uuidString).jpg")

        do {
            _ = try ThumbnailDistribution.download(forItemID: itemID, from: root, to: localFile)
        } catch {
            return nil
        }
        return loadCachedThumbnail(at: localFile)
    }

    /// Generates covers for a whole batch of items, several at a time.
    ///
    /// Sized against the machine rather than run one by one: on a library of tens
    /// of thousands, serial generation takes hours that the volume and the CPU
    /// both spend mostly idle. Results go to the disk cache only — holding every
    /// cover in memory would just evict what the user is looking at.
    nonisolated static func generateThumbnails(
        for requests: [ThumbnailRequest],
        progress: @escaping @MainActor (Int) -> Void
    ) async -> CoverExtractionOutcomes {
        guard !requests.isEmpty else { return CoverExtractionOutcomes() }

        let width = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        var outcomes = CoverExtractionOutcomes()
        var completed = 0

        await withTaskGroup(of: (itemID: UUID, succeeded: Bool, reachable: Bool).self) { group in
            var next = 0
            while next < min(width, requests.count) {
                group.addTask(priority: .utility) { [request = requests[next]] in
                    let outcome = await ThumbnailCache.extractThumbnailInBackground(for: request)
                    return (request.itemID, outcome.image != nil, outcome.fileWasReachable)
                }
                next += 1
            }

            while let result = await group.next() {
                if result.succeeded {
                    outcomes.generated.append(result.itemID)
                } else if result.reachable {
                    outcomes.withoutCover.append(result.itemID)
                } else {
                    outcomes.unreachable.append(result.itemID)
                }

                completed += 1
                if completed % 20 == 0 {
                    let reached = completed
                    await progress(reached)
                }

                guard !Task.isCancelled, next < requests.count else { continue }
                group.addTask(priority: .utility) { [request = requests[next]] in
                    let outcome = await ThumbnailCache.extractThumbnailInBackground(for: request)
                    return (request.itemID, outcome.image != nil, outcome.fileWasReachable)
                }
                next += 1
            }
        }

        return outcomes
    }

    /// Scale down raw image data to a high-quality thumbnail using CGImageSource.
    /// This is extremely memory-efficient as it does not load the full-res image into RAM.
    nonisolated static func createThumbnail(from data: Data, maxPixelSize: Int = 400) -> NSImage? {
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
    nonisolated static func loadCachedThumbnail(at url: URL) -> NSImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, imageOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    /// Retrieves the cover image for an item, loading from Memory -> Disk -> Source
    /// Extraction. Requests for the same item share a single load, so selecting a
    /// cover that a prefetch is already working on never extracts it twice.
    func getCoverImage(for request: ThumbnailRequest) async -> NSImage? {
        // 1. Memory Cache check (instant)
        if let cachedImage = thumbnailMemoryStore.image(forKey: request.itemID.uuidString) {
            return cachedImage
        }

        if let runningLoad = inFlightLoads[request.itemID] {
            return await runningLoad.value
        }

        let load = Task { await self.performLoad(request) }
        inFlightLoads[request.itemID] = load
        let image = await load.value
        inFlightLoads[request.itemID] = nil
        return image
    }

    /// How many covers a prefetch window loads at once. Enough to get through a
    /// large window at a useful rate, few enough that a network volume (SMB/AFP)
    /// still has room for the cover actually on screen.
    private static let maxConcurrentPrefetches = 3

    /// Warms the memory cache for covers the user is about to reach. A new window
    /// replaces the one before it.
    func prefetch(_ requests: [ThumbnailRequest]) {
        prefetchTask?.cancel()

        let pending = requests.filter { request in
            thumbnailMemoryStore.image(forKey: request.itemID.uuidString) == nil
                && !missingCoverKeys.contains(request.itemID.uuidString)
        }
        guard !pending.isEmpty else {
            prefetchTask = nil
            return
        }

        prefetchTask = Task {
            // Leave the volume to the cover actually on screen, which starts
            // loading first. The caller has already waited for the cursor to
            // settle, so this only orders the two.
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }

            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < min(Self.maxConcurrentPrefetches, pending.count) {
                    let request = pending[next]
                    group.addTask { _ = await Self.renderedCoverImage(for: request) }
                    next += 1
                }

                // Keep the window sliding: start the next cover each time one
                // finishes, nearest to the cursor first.
                while await group.next() != nil {
                    guard !Task.isCancelled, next < pending.count else { continue }
                    let request = pending[next]
                    group.addTask { _ = await Self.renderedCoverImage(for: request) }
                    next += 1
                }
            }
        }
    }

    private func performLoad(_ request: ThumbnailRequest) async -> NSImage? {
        let cacheKeyString = request.itemID.uuidString

        if let rendered = await Self.renderedCoverImage(for: request) {
            return rendered
        }

        if missingCoverKeys.contains(cacheKeyString) {
            return nil
        }

        // 3. Source Extraction
        // Bookmark resolution, the read over the volume, and the decode/re-encode
        // all run on a dedicated blocking-I/O lane. Keeping the CPU work off the actor
        // matters as much as keeping the I/O off it: on the actor, a prefetched
        // cover being decoded would stall the disk read for the cover on screen.
        let outcome = await Self.extractThumbnailInBackground(for: request)

        guard let thumbnail = outcome.image else {
            // A disconnected NAS is temporary. Remembering that as "this book has
            // no cover" would suppress every retry until the app was restarted.
            if outcome.fileWasReachable {
                missingCoverKeys.insert(cacheKeyString)
            }
            return nil
        }

        // Put in Memory Cache
        thumbnailMemoryStore.store(thumbnail, forKey: cacheKeyString)
        missingCoverKeys.remove(cacheKeyString)
        return thumbnail
    }

    /// Drops what is held in memory without touching the files on disk, so covers
    /// regenerated by a bulk pass are picked up instead of the stale ones.
    func invalidateMemoryCache() {
        thumbnailMemoryStore.removeAll()
        missingCoverKeys.removeAll()
    }

    /// Invalidates only files that changed. Bulk transfer commonly changes a few
    /// covers; dropping the entire decoded cache makes unrelated visible rows pay
    /// the disk-decode cost again.
    func invalidate(itemIDs: some Sequence<UUID>) {
        for itemID in itemIDs {
            let key = itemID.uuidString
            thumbnailMemoryStore.remove(forKey: key)
            missingCoverKeys.remove(key)
        }
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
        guard let thumbnail = Self.createThumbnail(from: imageData) else { return nil }

        let localThumbnailURL = thumbnailCacheDirectory.appendingPathComponent("\(itemID.uuidString).jpg")
        if let tiff = thumbnail.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpegData = bitmap.representation(using: .jpeg, properties: [:]) {
            try? jpegData.write(to: localThumbnailURL, options: .atomic)
        }

        thumbnailMemoryStore.store(thumbnail, forKey: itemID.uuidString)
        missingCoverKeys.remove(itemID.uuidString)
        return thumbnail
    }

    /// Clears both memory and disk cache.
    func clearCache() {
        prefetchTask?.cancel()
        prefetchTask = nil
        thumbnailMemoryStore.removeAll()
        missingCoverKeys.removeAll()
        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(at: thumbnailCacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
