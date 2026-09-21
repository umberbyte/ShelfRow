//
//  ThumbnailDistributionCoordinator.swift
//  ShelfRow
//

import AppKit
import Foundation
import OSLog
import SwiftData

/// Owns the thumbnail distribution folder: which one it is, whether it can be
/// reached, and the runs that move files to and from it.
///
/// Access to the folder is a security-scoped bookmark, which is device-specific
/// and so lives in the local store alongside the other one. Resolving it means
/// holding the access open for as long as a run lasts, which is why every
/// transfer goes through here rather than reaching for the folder itself.
@Observable
@MainActor
final class ThumbnailDistributionCoordinator {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "ThumbnailDistribution")

    private enum DefaultsKey {
        static let autoFetch = "thumbnailAutoFetchEnabled"
        static let concurrency = "thumbnailTransferConcurrency"
        static let bulkOffered = "thumbnailBulkFetchOffered"
    }

    enum RootStatus: Equatable {
        case notChosen
        case checking
        case ready(UUID)
        case problem(ThumbnailDistribution.RootProblem)

        var isReady: Bool { if case .ready = self { return true } else { return false } }

        var message: String {
            switch self {
            case .notChosen: return "配布元フォルダが未設定です。"
            case .checking: return "配布元への接続を確認しています。"
            case .ready: return "配布元に接続できます。"
            case .problem(let problem): return problem.message
            }
        }
    }

    /// What a run is doing, for the banner and the settings pane.
    struct Activity: Equatable {
        enum Kind: Equatable {
            case uploading
            case fetching

            var label: String {
                switch self {
                case .uploading: return "サムネイルを配布元へ登録中"
                case .fetching: return "サムネイルを取得中"
                }
            }
        }

        var kind: Kind
        var done: Int
        var total: Int
    }

    /// A fetch large enough to be worth asking about first.
    struct BulkFetchOffer: Equatable {
        var count: Int
        var bytes: Int
        var hasRoom: Bool
    }

    /// Above either of these, a fetch is announced rather than simply done. A
    /// handful of covers after an edit on another Mac is not worth a dialog; a
    /// gigabyte after a bulk regeneration is.
    private static let quietFetchCount = 500
    private static let quietFetchBytes = 100 * 1024 * 1024
    /// New covers generated here go up without ceremony while there are few of
    /// them. The library-sized case is the migration, which has its own button
    /// because it rewrites every record and iCloud carries all of it.
    private static let quietUploadCount = 500

    /// The mode the library is open in. Distribution only has a job while the
    /// library is shared: `coverVersion`, which decides who fetches what, only
    /// reaches the other devices through iCloud. With syncing off, this device is
    /// alone with its covers and the folder is nobody's business.
    private(set) var libraryMode: LibraryMode = .local

    private(set) var status: RootStatus = .notChosen
    private(set) var counts: CoverDistributionCounts?
    private(set) var activity: Activity?
    private(set) var lastMessage: String?
    /// Set when a fetch is waiting on the person's word.
    private(set) var pendingOffer: BulkFetchOffer?

    /// The folder, while access to it is open.
    private var root: URL?
    /// What the folder says it holds. Re-read whenever the folder is opened, and
    /// updated in place when this device adds to it.
    private var manifest = ThumbnailDistribution.Manifest()
    private var accessHeld = false
    private var store: CoverDistributionStore?
    private var runTask: Task<Void, Never>?
    private var rootResolutionTask: Task<Void, Never>?
    private var automaticWorkTask: Task<Void, Never>?
    private var automaticPlanInProgress = false

    private struct ResolvedRoot: Sendable {
        let url: URL
        let accessHeld: Bool
        let marker: ThumbnailDistribution.Marker
        let manifest: ThumbnailDistribution.Manifest
        let refreshedBookmark: Data?
    }

    /// The transfer layer reports progress from a sendable background closure.
    /// The coordinator itself is only dereferenced again on the main actor.
    nonisolated private final class WeakCoordinatorBox: @unchecked Sendable {
        weak var value: ThumbnailDistributionCoordinator?

        init(_ value: ThumbnailDistributionCoordinator) {
            self.value = value
        }
    }

    var isRunning: Bool { activity != nil }

    /// Whether files may move between this device and the folder at all.
    var isActive: Bool { libraryMode == .cloud && status.isReady }

    /// Why nothing will happen, when nothing will.
    var inactiveReason: String? {
        if libraryMode != .cloud {
            return "iCloud同期がオフのため、サムネイルの配布は行いません。"
        }
        return status.isReady ? nil : status.message
    }

    var autoFetchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoFetchEnabled, forKey: DefaultsKey.autoFetch) }
    }

    var concurrency: Int {
        didSet { UserDefaults.standard.set(concurrency, forKey: DefaultsKey.concurrency) }
    }

    init() {
        let defaults = UserDefaults.standard
        autoFetchEnabled = defaults.object(forKey: DefaultsKey.autoFetch) as? Bool ?? true
        let stored = defaults.integer(forKey: DefaultsKey.concurrency)
        concurrency = ThumbnailTransfer.concurrencyRange.contains(stored)
            ? stored
            : ThumbnailTransfer.defaultConcurrency
    }

    // MARK: - Opening

    /// Called once the library store is open, and again after it is reopened in a
    /// different mode.
    func attach(to container: ModelContainer, mode: LibraryMode) {
        store = CoverDistributionStore(modelContainer: container)
        libraryMode = mode
        resolveRoot()
        // Root validation starts asynchronously. The library-sized inventory is
        // delayed until after the first window has had time to render.
    }

    /// Whether this device has ever been offered a bulk fetch, which is what makes
    /// the first one an explicit choice and the rest quiet (§21.7).
    var hasBeenOfferedBulkFetch: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.bulkOffered)
    }

    func noteBulkFetchOffered() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.bulkOffered)
    }

    // MARK: - Choosing the folder

    /// Takes a folder the user picked, initialising it if it is not a root yet.
    func adoptRoot(at url: URL, initialiseIfNeeded: Bool) {
        releaseRoot()

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            BookmarkVault.shared.setBookmark(bookmark, for: LocalBookmark.thumbnailRootID)
        } catch {
            Self.logger.error("Could not keep access to the distribution folder: \(error.localizedDescription, privacy: .public)")
            lastMessage = "配布元フォルダへのアクセス権を保存できませんでした: \(error.localizedDescription)"
            return
        }

        beginResolvingRoot(
            bookmark: BookmarkVault.shared.bookmark(for: LocalBookmark.thumbnailRootID),
            initialiseIfNeeded: initialiseIfNeeded,
            refreshCountsWhenDone: true
        )
    }

    func forgetRoot() {
        releaseRoot()
        BookmarkVault.shared.setBookmark(nil, for: LocalBookmark.thumbnailRootID)
        status = .notChosen
        lastMessage = nil
    }

    /// Reopens the folder chosen earlier. Not being able to reach it is ordinary —
    /// the share is not mounted, the machine is somewhere else — so it is reported
    /// as a status rather than an error.
    private func resolveRoot() {
        guard let bookmark = BookmarkVault.shared.bookmark(for: LocalBookmark.thumbnailRootID) else {
            status = .notChosen
            return
        }
        beginResolvingRoot(bookmark: bookmark, initialiseIfNeeded: false, refreshCountsWhenDone: false)
    }

    private func beginResolvingRoot(
        bookmark: Data?,
        initialiseIfNeeded: Bool,
        refreshCountsWhenDone: Bool
    ) {
        rootResolutionTask?.cancel()
        guard let bookmark else {
            status = .notChosen
            return
        }
        status = .checking
        lastMessage = nil

        rootResolutionTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.resolveRootOffMain(bookmark: bookmark, initialiseIfNeeded: initialiseIfNeeded)
            }.value
            guard !Task.isCancelled, let self else {
                if case .success(let resolved) = result, resolved.accessHeld {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
                return
            }
            self.rootResolutionTask = nil
            switch result {
            case .success(let resolved):
                self.root = resolved.url
                self.accessHeld = resolved.accessHeld
                self.status = .ready(resolved.marker.libraryID)
                self.publishRootForCoverGeneration(resolved.url, manifest: resolved.manifest)
                if let refreshedBookmark = resolved.refreshedBookmark {
                    BookmarkVault.shared.setBookmark(refreshedBookmark, for: LocalBookmark.thumbnailRootID)
                }
                if initialiseIfNeeded {
                    self.lastMessage = "配布元フォルダを確認しました。"
                }
                if refreshCountsWhenDone {
                    await self.refreshCounts()
                }
                self.scheduleAutomaticWork(after: .seconds(5))
            case .failure(let problem):
                self.status = .problem(problem)
                self.lastMessage = problem.message
            }
        }
    }

    nonisolated private static func resolveRootOffMain(
        bookmark: Data,
        initialiseIfNeeded: Bool
    ) -> Result<ResolvedRoot, ThumbnailDistribution.RootProblem> {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return .failure(.unreachable)
        }

        let accessHeld = url.startAccessingSecurityScopedResource()
        let validation: Result<ThumbnailDistribution.Marker, ThumbnailDistribution.RootProblem>
        switch ThumbnailDistribution.validate(root: url) {
        case .failure(.notADistributionFolder) where initialiseIfNeeded:
            do {
                validation = .success(try ThumbnailDistribution.initialiseRoot(at: url))
            } catch {
                validation = .failure(.unreadableMarker(error.localizedDescription))
            }
        case let result:
            validation = result
        }

        guard case .success(let marker) = validation else {
            if accessHeld { url.stopAccessingSecurityScopedResource() }
            if case .failure(let problem) = validation { return .failure(problem) }
            return .failure(.unreachable)
        }

        let refreshedBookmark = isStale
            ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        return .success(ResolvedRoot(
            url: url,
            accessHeld: accessHeld,
            marker: marker,
            manifest: ThumbnailDistribution.readManifest(in: url),
            refreshedBookmark: refreshedBookmark
        ))
    }

    /// Lets cover generation read from the folder before it opens an archive —
    /// but only while the library is shared. With syncing off there is no other
    /// device to have put anything there for this one.
    private func publishRootForCoverGeneration(
        _ url: URL,
        manifest loadedManifest: ThumbnailDistribution.Manifest
    ) {
        guard libraryMode == .cloud else {
            ThumbnailDistribution.currentRoot = nil
            manifest = ThumbnailDistribution.Manifest()
            return
        }
        ThumbnailDistribution.currentRoot = url
        manifest = loadedManifest
        ThumbnailDistribution.setPublishedCovers(manifest.itemIDs)
        Self.logger.info("The distribution folder lists \(self.manifest.entries.count, privacy: .public) covers")
    }

    private func releaseRoot() {
        rootResolutionTask?.cancel()
        rootResolutionTask = nil
        automaticWorkTask?.cancel()
        automaticWorkTask = nil
        if accessHeld, let root {
            root.stopAccessingSecurityScopedResource()
        }
        accessHeld = false
        root = nil
        ThumbnailDistribution.currentRoot = nil
    }

    // MARK: - Counting

    /// Counting walks the library, so it happens when someone is looking at the
    /// numbers or a run has just changed them — never on a timer.
    func refreshCounts() async {
        guard let store, isActive else {
            counts = nil
            return
        }
        counts = try? await store.counts(manifest: manifest)
    }

    /// What a bulk fetch would cost, for the sheet that asks about it.
    func pendingFetch() async -> (count: Int, bytes: Int)? {
        guard let store, let targets = try? await store.fetchTargets(manifest: manifest), !targets.isEmpty else { return nil }
        return (targets.count, targets.reduce(0) { $0 + $1.expectedBytes })
    }

    /// Whether the cache's volume has room for a fetch of this size, with the
    /// margin that keeps a full disk from being the way this is discovered.
    func hasRoomForFetch(bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        let values = try? ThumbnailCache.diskCacheDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return Double(available) >= Double(bytes) * 1.2
    }

    // MARK: - Runs

    /// Hands everything this device has to the distribution folder, moving each
    /// book's version along so the others learn of it through iCloud (§21.11).
    func uploadEverything(targets suppliedTargets: [CoverUploadTarget]? = nil) {
        let manifest = manifest
        start(.uploading) { [self] store, root, report in
            let targets: [CoverUploadTarget]
            if let suppliedTargets {
                targets = suppliedTargets
            } else {
                targets = (try? await store.uploadTargets(manifest: manifest)) ?? []
            }
            guard !targets.isEmpty else {
                return "配布元へ登録するサムネイルはありませんでした。"
            }
            report(0, targets.count)

            let results = await ThumbnailTransfer.upload(targets, to: root, concurrency: concurrency) { done in
                report(done, targets.count)
            }
            await store.recordUploaded(results)

            // The folder's index is what tells the other devices these exist, so
            // it is written last: an entry for a file that failed to arrive would
            // send them looking for something that is not there.
            let added = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                result.errorCode == nil
                    ? (result.itemID.uuidString,
                       ThumbnailDistribution.Manifest.Entry(version: result.version, bytes: result.bytes))
                    : nil
            })
            await self.recordInManifest(added, at: root)

            let failed = results.filter { $0.errorCode != nil }.count
            return failed == 0
                ? "\(results.count.formatted())件を配布元へ登録しました。"
                : "\((results.count - failed).formatted())件を登録しました。\(failed.formatted())件は書き込めませんでした。"
        }
    }

    /// Fetches everything this device is missing.
    func fetchEverything(targets suppliedTargets: [CoverFetchTarget]? = nil) {
        let manifest = manifest
        start(.fetching) { [self] store, root, report in
            let targets: [CoverFetchTarget]
            if let suppliedTargets {
                targets = suppliedTargets
            } else {
                targets = (try? await store.fetchTargets(manifest: manifest)) ?? []
            }
            guard !targets.isEmpty else {
                return "取得するサムネイルはありませんでした。"
            }
            report(0, targets.count)

            let results = await ThumbnailTransfer.fetch(targets, from: root, concurrency: concurrency) { done in
                report(done, targets.count)
            }
            await store.recordFetched(results)
            let changedIDs = Set(results.lazy.filter { $0.errorCode == nil }.map(\.itemID))
            await ThumbnailCache.shared.invalidate(itemIDs: changedIDs)
            if !changedIDs.isEmpty {
                await MainActor.run {
                    NotificationCenter.default.post(name: .coverDidChange, object: changedIDs)
                }
            }

            let failed = results.filter { $0.errorCode != nil }.count
            return failed == 0
                ? "\(results.count.formatted())件のサムネイルを取得しました。"
                : "\((results.count - failed).formatted())件を取得しました。\(failed.formatted())件は取得できませんでした。"
        }
    }

    /// Writes what this device added into the folder's index, and keeps the copy
    /// held here in step with it.
    private func recordInManifest(
        _ added: [String: ThumbnailDistribution.Manifest.Entry],
        at root: URL
    ) async {
        guard !added.isEmpty else { return }
        do {
            let updated = try await Task.detached(priority: .utility) {
                try ThumbnailDistribution.updateManifest(in: root, merging: added)
            }.value
            manifest = updated
            ThumbnailDistribution.setPublishedCovers(manifest.itemIDs)
        } catch {
            Self.logger.error("Could not update the distribution index: \(error.localizedDescription, privacy: .public)")
            lastMessage = "配布元の目録を更新できませんでした: \(error.localizedDescription)"
        }
    }

    func cancelRun() {
        runTask?.cancel()
    }

    /// Does what can be done without asking, and asks about the rest.
    ///
    /// Called at launch, after iCloud brings changes in, and when the folder
    /// becomes reachable. Being unable to reach the folder is not an error worth
    /// reporting — a laptop away from the NAS is in that state most of the day —
    /// so this simply does nothing until it can.
    func considerAutomaticWork() async {
        guard isActive, !isRunning, !automaticPlanInProgress,
              autoFetchEnabled, pendingOffer == nil, let store else { return }
        automaticPlanInProgress = true
        defer { automaticPlanInProgress = false }

        // Handing over a cover this device made is not the first device's
        // privilege — any Mac may generate the one book being looked at, and the
        // others should get it. What stays with the first device is the
        // library-sized registration, which has its own button: a run of that
        // size here would mean two Macs had generated the same twenty thousand
        // covers, which the rules above are there to prevent.
        guard let plan = try? await store.automaticPlan(manifest: manifest) else { return }

        if !plan.uploads.isEmpty, plan.uploads.count <= Self.quietUploadCount {
            uploadEverything(targets: plan.uploads)
            return
        }

        guard !plan.fetches.isEmpty else { return }
        let pending = (
            count: plan.fetches.count,
            bytes: plan.fetches.reduce(0) { $0 + $1.expectedBytes }
        )

        let quiet = hasBeenOfferedBulkFetch
            && pending.count < Self.quietFetchCount
            && pending.bytes < Self.quietFetchBytes
        guard !quiet else {
            fetchEverything(targets: plan.fetches)
            return
        }

        pendingOffer = BulkFetchOffer(
            count: pending.count,
            bytes: pending.bytes,
            hasRoom: hasRoomForFetch(bytes: pending.bytes)
        )
    }

    /// Coalesces CloudKit/root events before taking a library-sized cache
    /// inventory. A burst of remote saves should cause one pass, not one per
    /// record batch.
    func scheduleAutomaticWork(after delay: Duration = .seconds(2)) {
        automaticWorkTask?.cancel()
        automaticWorkTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.automaticWorkTask = nil
            await self.considerAutomaticWork()
        }
    }

    /// Accepts the offer.
    func acceptPendingFetch() {
        noteBulkFetchOffered()
        pendingOffer = nil
        fetchEverything()
    }

    /// Asks again next launch.
    func deferPendingFetch() {
        pendingOffer = nil
    }

    /// Stops asking and leaves covers to be fetched as they are looked at.
    func declineBulkFetching() {
        noteBulkFetchOffered()
        pendingOffer = nil
        autoFetchEnabled = false
    }

    private func start(
        _ kind: Activity.Kind,
        _ work: @escaping (CoverDistributionStore, URL, @escaping @Sendable (Int, Int) -> Void) async -> String
    ) {
        guard let store, let root, isActive, runTask == nil else { return }

        activity = Activity(kind: kind, done: 0, total: 0)
        lastMessage = nil
        let coordinator = WeakCoordinatorBox(self)

        runTask = Task { [weak self] in
            let report: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor in
                    guard coordinator.value?.activity != nil else { return }
                    coordinator.value?.activity = Activity(kind: kind, done: done, total: total)
                }
            }

            let message = await work(store, root, report)

            guard let self else { return }
            await MainActor.run {
                self.activity = nil
                self.runTask = nil
                self.lastMessage = message
            }
            await self.refreshCounts()
            self.scheduleAutomaticWork(after: .seconds(1))
        }
    }
}
