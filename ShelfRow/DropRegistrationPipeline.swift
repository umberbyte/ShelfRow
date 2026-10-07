import Foundation

nonisolated struct DroppedFileFact: Sendable {
    let url: URL
    let exists: Bool
    let isDirectory: Bool
    let bookmarkData: Data?
}

nonisolated struct DroppedFilePageCountRequest: Sendable {
    let itemID: UUID
    let url: URL
    let shouldApplyAutoBookType: Bool
}

nonisolated struct DroppedFilePageCountUpdate: Sendable {
    let itemID: UUID
    let pageCount: Int
    let shouldApplyAutoBookType: Bool
}

/// Pulls file URLs from a drop concurrently. Finder may provide many item
/// providers, and waiting for each provider before asking the next one adds the
/// individual hand-off latencies together.
nonisolated enum DroppedFileProviderLoader {
    private struct SendableProvider: @unchecked Sendable {
        let value: NSItemProvider
    }

    private struct IndexedURL: Sendable {
        let index: Int
        let url: URL
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        let wrapped = providers.map(SendableProvider.init)
        return await withTaskGroup(of: IndexedURL?.self) { group in
            for (index, provider) in wrapped.enumerated() {
                group.addTask {
                    guard let url = await loadURL(from: provider.value) else { return nil }
                    return IndexedURL(index: index, url: url)
                }
            }

            var loaded: [IndexedURL] = []
            loaded.reserveCapacity(providers.count)
            for await result in group {
                if let result { loaded.append(result) }
            }
            return loaded.sorted { $0.index < $1.index }.map(\.url)
        }
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

/// Performs the NAS-facing work before touching SwiftData. Work is bounded so
/// a large drop does not flood one share with simultaneous metadata requests.
nonisolated enum DroppedFilePreflight {
    static func inspect(
        urls: [URL],
        maximumConcurrentRequests: Int = 8
    ) async -> [DroppedFileFact] {
        guard !urls.isEmpty else { return [] }
        let batchSize = max(1, maximumConcurrentRequests)
        var ordered = Array<DroppedFileFact?>(repeating: nil, count: urls.count)

        for start in stride(from: 0, to: urls.count, by: batchSize) {
            let end = min(start + batchSize, urls.count)
            await withTaskGroup(of: (Int, DroppedFileFact).self) { group in
                for index in start..<end {
                    let url = urls[index]
                    group.addTask {
                        (index, inspect(url: url))
                    }
                }
                for await (index, fact) in group {
                    ordered[index] = fact
                }
            }
        }
        return ordered.compactMap { $0 }
    }

    /// One file, synchronously. The batch above is what a drop needs; a single
    /// file is what the command line has, and it has no one to stay responsive
    /// for.
    static func inspect(url: URL) -> DroppedFileFact {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let bookmarkData: Data?
        if exists {
            bookmarkData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            bookmarkData = nil
        }
        return DroppedFileFact(
            url: url,
            exists: exists,
            isDirectory: isDirectory.boolValue,
            bookmarkData: bookmarkData
        )
    }
}

/// Page counting is follow-up metadata enrichment. It starts only after the
/// items are visible and uses modest concurrency so it cannot starve a NAS or
/// delay the registration transaction.
nonisolated enum DroppedFilePageCounter {
    static func count(
        _ requests: [DroppedFilePageCountRequest],
        maximumConcurrentRequests: Int = 2
    ) async -> [DroppedFilePageCountUpdate] {
        guard !requests.isEmpty else { return [] }
        let batchSize = max(1, maximumConcurrentRequests)
        var ordered = Array<DroppedFilePageCountUpdate?>(repeating: nil, count: requests.count)

        for start in stride(from: 0, to: requests.count, by: batchSize) {
            let end = min(start + batchSize, requests.count)
            await withTaskGroup(of: (Int, DroppedFilePageCountUpdate).self) { group in
                for index in start..<end {
                    let request = requests[index]
                    group.addTask {
                        let update = DroppedFilePageCountUpdate(
                            itemID: request.itemID,
                            pageCount: ItemFileAccess.listPages(at: request.url).count,
                            shouldApplyAutoBookType: request.shouldApplyAutoBookType
                        )
                        return (index, update)
                    }
                }
                for await (index, update) in group {
                    ordered[index] = update
                }
            }
        }
        return ordered.compactMap { $0 }
    }
}
