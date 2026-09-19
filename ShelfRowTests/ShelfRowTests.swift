//
//  ShelfRowTests.swift
//  ShelfRowTests
//
//  Created by Go Sugawara on 2026/09/16.
//

import Testing
import Foundation
import ImageIO
import CoreGraphics
import SwiftData
import CloudKit
@testable import ShelfRow

struct ShelfRowTests {

    @Test func pathParserSplitsExternalVolumes() {
        let result = PathParser.split("/Volumes/MangaDrive/Completed/Title.zip")

        #expect(result.volumePath == "/Volumes/MangaDrive")
        #expect(result.volumeName == "MangaDrive")
        #expect(result.relativePath == "Completed/Title.zip")
    }

    @Test func pathParserUsesBootVolumeForNonVolumesPaths() {
        let result = PathParser.split("/Users/me/Books/Title.zip")

        #expect(result.volumePath == "/")
        #expect(result.volumeName == "Boot Volume")
        #expect(result.relativePath == "Users/me/Books/Title.zip")
    }

    @Test func fileNameParserExtractsLeadingMetadataOnly() {
        let parsed = FileNameParser.parse(fileName: "(同人誌)(C99)[作者名]作品タイトル[DL版].zip")

        #expect(parsed.genre == "同人誌")
        #expect(parsed.author == "作者名")
        #expect(parsed.title == "作品タイトル")
    }

    @Test func fileNameParserUsesCustomFormatPlaceholders() {
        let parsed = FileNameParser.parse(
            fileName: "(コミック)[作家名] 作品タイトル {原作名} #青 #赤 - 厚い本.zip",
            format: "(@genre)[@author] @title {@relation} @keywordA @keywordB - @type"
        )

        #expect(parsed.genre == "コミック")
        #expect(parsed.author == "作家名")
        #expect(parsed.title == "作品タイトル")
        #expect(parsed.relation == "原作名")
        #expect(parsed.keywordA == "#青")
        #expect(parsed.keywordB == "#赤")
        #expect(parsed.type == "厚い本")
    }

    @Test func fileNameParserUsesNestedCustomFormatPlaceholders() {
        let parsed = FileNameParser.parse(
            fileName: "[ほげふが(太郎)] 書籍名ですよ(1).zip",
            format: "[@author(@keywordA)] @title"
        )

        #expect(parsed.author == "ほげふが")
        #expect(parsed.keywordA == "太郎")
        #expect(parsed.title == "書籍名ですよ(1)")
    }

    @Test func fileNameParserLeavesMissingNestedPlaceholderEmpty() {
        let parsed = FileNameParser.parse(
            fileName: "[ほげふが]書籍名ですよ(1).zip",
            format: "[@author(@keywordA)] @title"
        )

        #expect(parsed.author == "ほげふが")
        #expect(parsed.keywordA.isEmpty)
        #expect(parsed.title == "書籍名ですよ(1)")
    }

    @Test func fileNameParserFallsBackWhenCustomFormatDoesNotMatch() {
        let parsed = FileNameParser.parse(
            fileName: "(同人誌)[作者名]作品タイトル.zip",
            format: "未一致 @title"
        )

        #expect(parsed.genre == "同人誌")
        #expect(parsed.author == "作者名")
        #expect(parsed.title == "作品タイトル")
    }

    @Test func bookTypeAutoClassifierUsesNewRegistrationPageRules() {
        #expect(BookTypeAutoClassifier.classify(pageCount: 21) == 0)
        #expect(BookTypeAutoClassifier.classify(pageCount: 50) == 0)
        #expect(BookTypeAutoClassifier.classify(pageCount: 11) == 1)
        #expect(BookTypeAutoClassifier.classify(pageCount: 20) == 1)
        #expect(BookTypeAutoClassifier.classify(pageCount: 1) == 2)
        #expect(BookTypeAutoClassifier.classify(pageCount: 10) == 2)
    }

    @Test func bookTypeAutoClassifierLeavesUnspecifiedRangesUnset() {
        #expect(BookTypeAutoClassifier.classify(pageCount: 0) == nil)
    }

    @Test func coverSelectorPrefersSmallestNumberInLargestSequence() {
        let pages = [
            BookPage(id: 0, name: "flyer.jpg"),
            BookPage(id: 1, name: "book_003.jpg"),
            BookPage(id: 2, name: "book_001.jpg"),
            BookPage(id: 3, name: "book_002.jpg"),
            BookPage(id: 4, name: "extra_001.jpg")
        ]

        #expect(CoverSelector.bestCoverPage(from: pages)?.name == "book_001.jpg")
    }

    @Test func coverSelectorRequiresSequenceForRepairCover() {
        let pages = [
            BookPage(id: 0, name: "cover.jpg"),
            BookPage(id: 1, name: "sample.jpg")
        ]

        #expect(CoverSelector.bestSequentialCoverPage(from: pages) == nil)
        #expect(CoverSelector.bestCoverPage(from: pages)?.name == "cover.jpg")
    }

    @Test func imageCompletenessRejectsTruncatedJpegAndPng() {
        let completeJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
        let truncatedJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let completePng = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
            0xAE, 0x42, 0x60, 0x82
        ])
        let truncatedPng = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x00
        ])

        #expect(CoverSelector.imageDataLooksComplete(completeJpeg))
        #expect(!CoverSelector.imageDataLooksComplete(truncatedJpeg))
        #expect(CoverSelector.imageDataLooksComplete(completePng))
        #expect(!CoverSelector.imageDataLooksComplete(truncatedPng))
    }

    @Test func preferredCoverFallsBackFromMonochromeSequenceToFirstPortraitColor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let colorCover = directory.appendingPathComponent("P001.jpg")
        let monoSequenceStart = directory.appendingPathComponent("P007.png")
        let monoSequenceNext = directory.appendingPathComponent("P008.png")
        let monoSequenceThird = directory.appendingPathComponent("P009.png")

        try makeTestImage(width: 40, height: 80, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1), type: .jpeg)
            .write(to: colorCover)
        let monoData = try makeTestImage(width: 40, height: 80, color: CGColor(gray: 0.5, alpha: 1), type: .png)
        try monoData.write(to: monoSequenceStart)
        try monoData.write(to: monoSequenceNext)
        try monoData.write(to: monoSequenceThird)

        let selected = try #require(CoverSelector.preferredCoverData(bookURL: directory))
        #expect(selected == (try Data(contentsOf: colorCover)))
    }

    @Test func smartConditionsRequireAllEnabledConditions() {
        let item = Item(
            relativePath: "Books/Title.zip",
            title: "Blue Archive",
            author: "Circle",
            rating: 4,
            isUnread: true,
            genre: "Comic",
            bookType: 1
        )
        var conditions = SmartConditions()
        conditions.keyword = .init(field: "Title", text: "Archive", mode: 0)
        conditions.types = [1]
        conditions.rates = [4]
        conditions.unreadOnly = true

        #expect(SmartConditionsCodec.matches(item, conditions: conditions))
    }

    @Test func smartConditionsCanGroupItemsByCustomMetadataField() {
        let cityPhoto = Item(
            relativePath: "Photos/City.zip",
            title: "Evening Walk",
            genre: "街",
            bookType: 3
        )
        let mountainPhoto = Item(
            relativePath: "Photos/Mountain.zip",
            title: "Trail",
            genre: "山",
            bookType: 3
        )
        var conditions = SmartConditions()
        conditions.keyword = .init(field: "Genre", text: "街", mode: 0)

        #expect(SmartConditionsCodec.matches(cityPhoto, conditions: conditions))
        #expect(!SmartConditionsCodec.matches(mountainPhoto, conditions: conditions))
    }

    @Test func smartKeywordModesMatchEditorLabels() {
        let item = Item(relativePath: "Books/Title.zip", title: "街の写真集")

        var exact = SmartConditions()
        exact.keyword = .init(field: "Title", text: "街の写真集", mode: 2)
        #expect(SmartConditionsCodec.matches(item, conditions: exact))

        var contains = SmartConditions()
        contains.keyword = .init(field: "Title", text: "街", mode: 0)
        #expect(SmartConditionsCodec.matches(item, conditions: contains))

        var excludes = SmartConditions()
        excludes.keyword = .init(field: "Title", text: "山", mode: 1)
        #expect(SmartConditionsCodec.matches(item, conditions: excludes))
    }

    @Test func coverPrefetchWindowOrdersNeighborsNearestFirst() {
        let indices = CoverPrefetchWindow.indices(around: 5, count: 20, radius: 3)

        #expect(indices == [6, 4, 7, 3, 8, 2])
    }

    @Test func coverPrefetchWindowClampsToListBounds() {
        #expect(CoverPrefetchWindow.indices(around: 0, count: 3, radius: 5) == [1, 2])
        #expect(CoverPrefetchWindow.indices(around: 2, count: 3, radius: 5) == [1, 0])
    }

    @Test func bulkGenerationTargetsAThumbnailThatIsNotThere() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reasons = try #require(ContentView.thumbnailRepairReasons(
            at: directory.appendingPathComponent("absent.jpg")
        ))

        #expect(reasons.isMissing)
        #expect(!reasons.isLandscape)
        #expect(!reasons.isMonochrome)
    }

    @Test func bulkGenerationTargetsAnEmptyThumbnailFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("truncated.jpg")
        try Data().write(to: thumbURL)

        let reasons = try #require(ContentView.thumbnailRepairReasons(at: thumbURL))

        #expect(reasons.isMissing)
    }

    @Test func bulkGenerationRepicksALandscapeThumbnailThatIsAlreadyOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("landscape.jpg")
        try makeTestImage(width: 80, height: 40, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1), type: .jpeg)
            .write(to: thumbURL)

        let reasons = try #require(ContentView.thumbnailRepairReasons(at: thumbURL))

        #expect(reasons.isLandscape)
        #expect(!reasons.isMissing)
    }

    @Test func everyBookARunTouchedCountsAsAttempted() async throws {
        let store = try makeCoverExtractionStore()
        let generated = UUID()
        let withoutCover = UUID()
        let unreachable = UUID()

        // Whatever came of it, a book is attempted once: an unmounted volume is on
        // record the same as a cover that was produced, so the next run leaves all
        // three alone.
        await store.record(CoverExtractionOutcomes(
            generated: [generated],
            withoutCover: [withoutCover],
            unreachable: [unreachable]
        ))

        let attempted = await store.attemptedItemIDs()
        #expect(attempted == [generated, withoutCover, unreachable])
    }

    @Test func coverExtractionStoreKeepsTheLatestOutcomePerBook() async throws {
        let store = try makeCoverExtractionStore()
        let book = UUID()

        await store.record(CoverExtractionOutcomes(withoutCover: [book]))
        await store.record(CoverExtractionOutcomes(generated: [book]))

        let attempted = await store.attemptedItemIDs()
        #expect(attempted == [book])
    }

    @Test func coverExtractionStoreForgetsBooksNoLongerInTheLibrary() async throws {
        let store = try makeCoverExtractionStore()
        let kept = UUID()
        let deleted = UUID()

        await store.record(CoverExtractionOutcomes(generated: [kept, deleted]))
        await store.prune(keeping: [kept])

        let attempted = await store.attemptedItemIDs()
        #expect(attempted == [kept])
    }

    private func makeCoverExtractionStore() throws -> CoverExtractionStore {
        let container = try ModelContainer(
            for: CoverExtractionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return CoverExtractionStore(modelContainer: container)
    }

    @Test func bulkGenerationRepicksAMonochromeThumbnailThatIsAlreadyOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("monochrome.png")
        try makeTestImage(width: 40, height: 80, color: CGColor(gray: 0.5, alpha: 1), type: .png)
            .write(to: thumbURL)

        let reasons = try #require(ContentView.thumbnailRepairReasons(at: thumbURL))

        #expect(reasons.isMonochrome)
        #expect(!reasons.isMissing)
    }

    @Test func bulkGenerationLeavesAGoodPortraitCoverAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("portrait.jpg")
        try makeTestImage(width: 40, height: 80, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1), type: .jpeg)
            .write(to: thumbURL)

        #expect(ContentView.thumbnailRepairReasons(at: thumbURL) == nil)
    }

    @Test func coverPrefetchWindowIsEmptyWithoutNeighborsToLoad() {
        #expect(CoverPrefetchWindow.indices(around: 0, count: 0, radius: 4).isEmpty)
        #expect(CoverPrefetchWindow.indices(around: 1, count: 5, radius: 0).isEmpty)
        #expect(CoverPrefetchWindow.indices(around: 9, count: 5, radius: 2).isEmpty)
        #expect(CoverPrefetchWindow.indices(around: 0, count: 1, radius: 8).isEmpty)
    }

    private enum TestImageType {
        case jpeg
        case png

        var utType: CFString {
            switch self {
            case .jpeg: return "public.jpeg" as CFString
            case .png: return "public.png" as CFString
            }
        }
    }

    private func makeTestImage(width: Int, height: Int, color: CGColor, type: TestImageType) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.utType, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

// MARK: - Multi-device sync

@MainActor
struct LibraryModeTests {

    @Test func syncingNeedsBothTheSettingAndAnAccount() {
        #expect(LibraryStore.effectiveMode(syncEnabled: true, accountAvailable: true) == .cloud)
        #expect(LibraryStore.effectiveMode(syncEnabled: true, accountAvailable: false) == .local)
        #expect(LibraryStore.effectiveMode(syncEnabled: false, accountAvailable: true) == .local)
        #expect(LibraryStore.effectiveMode(syncEnabled: false, accountAvailable: false) == .local)
    }

    @Test func onlyAnAvailableAccountCountsAsAvailable() {
        #expect(CloudAccountMonitor.Availability.available.isAvailable)
        #expect(!CloudAccountMonitor.Availability.checking.isAvailable)
        #expect(!CloudAccountMonitor.Availability.noAccount.isAvailable)
        #expect(!CloudAccountMonitor.Availability.restricted.isAvailable)
        #expect(!CloudAccountMonitor.Availability.unavailable("圏外").isAvailable)
    }

    @Test func anUnavailableAccountExplainsWhy() {
        let status = CloudAccountMonitor.Availability.unavailable("一時的に利用できません").statusText
        #expect(status.contains("一時的に利用できません"))
    }
}

@MainActor
struct BookmarkVaultTests {

    /// Each test gets its own vault and its own in-memory store. Never
    /// `BookmarkVault.shared`: the test host is the app itself, and taking its
    /// vault away mid-write is an exception no `try` can catch.
    /// Mirrors the app's two-store layout: the library in one, the bookmarks in
    /// their own. `LocalBookmark` belongs to a named configuration there, and a
    /// container that puts it anywhere else leaves Core Data with no store
    /// eligible to save it.
    private func makeContainer() throws -> ModelContainer {
        let library = ModelConfiguration(
            "Library",
            schema: Schema([Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self]),
            isStoredInMemoryOnly: true
        )
        let local = ModelConfiguration(
            "Local",
            schema: Schema([LocalBookmark.self]),
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: Volume.self, Item.self, Shelf.self, CoverExtractionRecord.self, LocalBookmark.self,
            configurations: library, local
        )
    }

    @Test func storesAndRemovesABookmark() throws {
        let container = try makeContainer()
        let vault = BookmarkVault()
        vault.attach(to: container)

        let targetID = UUID()
        #expect(!vault.hasBookmark(for: targetID))

        vault.setBookmark(Data([1, 2, 3]), for: targetID)
        #expect(vault.bookmark(for: targetID) == Data([1, 2, 3]))

        vault.setBookmark(Data([4]), for: targetID)
        #expect(vault.bookmark(for: targetID) == Data([4]))

        vault.setBookmark(nil, for: targetID)
        #expect(!vault.hasBookmark(for: targetID))
    }

    @Test func reloadsBookmarksFromTheStore() throws {
        let container = try makeContainer()
        let vault = BookmarkVault()
        vault.attach(to: container)

        let targetID = UUID()
        vault.setBookmark(Data([9, 9]), for: targetID)

        // Reattaching is what a mode switch does: the in-memory copy is dropped
        // and everything is read back from the local store.
        vault.attach(to: container)
        #expect(vault.bookmark(for: targetID) == Data([9, 9]))
    }

    @Test func movesBookmarksOffTheSyncedModelsOnce() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let volume = Volume(name: "NAS", lastKnownPath: "/Volumes/NAS")
        volume.bookmarkData = Data([1])
        context.insert(volume)

        let item = Item(volume: volume, relativePath: "a.zip", title: "A")
        item.bookmarkData = Data([2])
        context.insert(item)
        try context.save()

        let defaults = try #require(UserDefaults(suiteName: "BookmarkVaultTests-\(UUID().uuidString)"))
        let vault = BookmarkVault()
        vault.attach(to: container)
        vault.adoptBookmarksStoredOnModels(defaults: defaults)

        #expect(vault.bookmark(for: volume.id) == Data([1]))
        #expect(vault.bookmark(for: item.id) == Data([2]))
        // Emptied so the shared library carries nothing device-specific.
        #expect(volume.bookmarkData == nil)
        #expect(item.bookmarkData == nil)

        // A second run must not undo a bookmark the user has since replaced.
        vault.setBookmark(Data([7]), for: volume.id)
        vault.adoptBookmarksStoredOnModels(defaults: defaults)
        #expect(vault.bookmark(for: volume.id) == Data([7]))
    }
}

struct CloudSyncRetryTests {

    private func ckError(_ code: CKError.Code, retryAfter: TimeInterval? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let retryAfter {
            info[CKErrorRetryAfterKey] = retryAfter
        }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: info)
    }

    @Test func rateLimitingIsWorthWaitingOut() {
        // What seeding a 19k-book library earns from CloudKit all day long.
        let interval = CloudAccountMonitor.retryInterval(for: ckError(.requestRateLimited, retryAfter: 22))
        #expect(interval == 22)
    }

    @Test func throttlingCountsEvenWithoutAnInterval() {
        // The event's error does not always carry CKRetryAfter, so the code has
        // to be enough on its own.
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.requestRateLimited)) == 0)
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.zoneBusy)) == 0)
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.serviceUnavailable)) == 0)
    }

    @Test func aWrappedCloudKitErrorIsStillFound() {
        let inner = ckError(.requestRateLimited, retryAfter: 30)
        let outer = NSError(domain: NSCocoaErrorDomain, code: 134400,
                            userInfo: [NSUnderlyingErrorKey: inner])
        #expect(CloudAccountMonitor.retryInterval(for: outer) == 30)
    }

    @Test func beingOfflinePassesOnItsOwn() {
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.networkUnavailable)) == 0)
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.networkFailure)) == 0)
    }

    @Test func aFullAccountIsNotFixedByWaiting() {
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.quotaExceeded)) == nil)
        #expect(CloudAccountMonitor.retryInterval(for: ckError(.notAuthenticated)) == nil)
    }

    @Test func aBacklogMeansStillWorking() {
        // The case a ninety-second timer got wrong: CloudKit throttles a large
        // upload into bursts minutes apart, and the gap is not the end of it.
        #expect(CloudAccountMonitor.isBusy(pendingUploads: 4_000, isReceivingRounds: false))
    }

    @Test func arrivingRoundsMeanStillWorking() {
        // A device being filled from iCloud has nothing of its own to send.
        #expect(CloudAccountMonitor.isBusy(pendingUploads: 0, isReceivingRounds: true))
        #expect(CloudAccountMonitor.isBusy(pendingUploads: nil, isReceivingRounds: true))
    }

    @Test func nothingWaitingAndNothingArrivingIsDone() {
        #expect(!CloudAccountMonitor.isBusy(pendingUploads: 0, isReceivingRounds: false))
        #expect(!CloudAccountMonitor.isBusy(pendingUploads: nil, isReceivingRounds: false))
    }

    @Test func aPartialFailureReportsTheServersOwnReason() {
        // What a library first meets a production schema with: the outer error
        // says nothing, and the sentence naming the fix is two levels down.
        let inner = NSError(domain: CKErrorDomain, code: CKError.Code.invalidArguments.rawValue,
                            userInfo: ["ServerErrorDescription": "Cannot create new type CDMR in production schema"])
        let outer = NSError(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
                            userInfo: [CKPartialErrorsByItemIDKey: ["record": inner]])
        #expect(CloudAccountMonitor.describe(outer) == "Cannot create new type CDMR in production schema")
    }

    @Test func anErrorWithNothingToAddKeepsItsOwnWords() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4099,
                            userInfo: [NSLocalizedDescriptionKey: "何かが起きました"])
        #expect(CloudAccountMonitor.describe(error) == "何かが起きました")
        #expect(CloudAccountMonitor.describe(nil) == nil)
    }

    @Test func nonCloudKitErrorsAreLeftAlone() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4099)
        #expect(CloudAccountMonitor.retryInterval(for: error) == nil)
        #expect(CloudAccountMonitor.retryInterval(for: nil) == nil)
    }
}

/// The NAS folder thumbnails are handed around through.
struct ThumbnailDistributionTests {


    @Test func aThumbnailIsFiledUnderTheFirstTwoCharactersOfItsIdentifier() {
        let root = URL(fileURLWithPath: "/Volumes/NAS/ShelfRowThumbnails", isDirectory: true)
        let itemID = UUID(uuidString: "AB12CD34-0000-4000-A000-000000000001")!
        let url = ThumbnailDistribution.fileURL(forItemID: itemID, in: root)

        #expect(url.lastPathComponent == "\(itemID.uuidString).jpg")
        #expect(url.deletingLastPathComponent().lastPathComponent == "AB")
    }

    @Test func aFolderIsRecognisedOnlyOnceItHasBeenInitialised() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ShelfRowThumbnailsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // An ordinary folder is not a distribution root, and says so rather than
        // being treated as an empty one.
        #expect(ThumbnailDistribution.readMarker(in: root) == .failure(.notADistributionFolder))

        let marker = try ThumbnailDistribution.initialiseRoot(at: root)
        let readBack = try ThumbnailDistribution.readMarker(in: root).get()
        // Not compared whole: the timestamp goes through ISO 8601, which does
        // not carry the fraction of a second it was created with.
        #expect(readBack.libraryID == marker.libraryID)
        #expect(readBack.formatVersion == ThumbnailDistribution.formatVersion)
        #expect(readBack.createdBy == marker.createdBy)
    }

    @Test func aFolderThatIsNotThereReadsAsUnreachableRatherThanWrong() {
        let missing = URL(fileURLWithPath: "/Volumes/NotMounted-\(UUID().uuidString)", isDirectory: true)
        #expect(ThumbnailDistribution.readMarker(in: missing) == .failure(.unreachable))
    }

    @Test func aThumbnailSurvivesTheRoundTripThroughTheFolder() throws {
        let fileManager = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ShelfRowTransferTest-\(UUID().uuidString)", isDirectory: true)
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let itemID = UUID()
        let source = scratch.appendingPathComponent("source.jpg")
        let payload = Data("not really a jpeg, but bytes are bytes".utf8)
        try payload.write(to: source)

        try ThumbnailDistribution.upload(from: source, forItemID: itemID, to: root)
        #expect(fileManager.fileExists(atPath: ThumbnailDistribution.fileURL(forItemID: itemID, in: root).path))

        let destination = scratch.appendingPathComponent("fetched.jpg")
        let bytes = try ThumbnailDistribution.download(forItemID: itemID, from: root, to: destination)
        #expect(bytes == payload.count)
        #expect(try Data(contentsOf: destination) == payload)

        // Writing over an existing one is the ordinary case: a cover was redone.
        try ThumbnailDistribution.upload(from: source, forItemID: itemID, to: root)
    }

    @Test func aTornDownloadIsNotLeftBehindAsATemporaryFile() throws {
        let fileManager = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ShelfRowMissingTest-\(UUID().uuidString)", isDirectory: true)
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let destination = scratch.appendingPathComponent("fetched.jpg")
        #expect(throws: (any Error).self) {
            try ThumbnailDistribution.download(forItemID: UUID(), from: root, to: destination)
        }
        #expect(!fileManager.fileExists(atPath: destination.path))
    }

    @Test func transferWidthStaysWithinWhatTheShareCanTake() {
        #expect(ThumbnailTransfer.concurrencyRange.contains(ThumbnailTransfer.defaultConcurrency))
        #expect(ThumbnailTransfer.concurrencyRange.lowerBound >= 1)
    }

    @Test func theTwoConfigurationContainerOpensWithEveryModelItNames() throws {
        // The mistake this catches is not a compile error: a model named by a
        // configuration but missing from the container's own schema opens as
        // `configurationSchemaNotFoundInContainerSchema`, which the app cannot
        // start from. Opening it here, the way the app does, is the only check.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ShelfRowStoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = ModelConfiguration(
            "Library",
            schema: Schema(LibraryStore.libraryModels),
            url: directory.appendingPathComponent("default.store"),
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "Local",
            schema: Schema(LibraryStore.localModels),
            url: directory.appendingPathComponent("local.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: Schema(LibraryStore.libraryModels + LibraryStore.localModels),
            configurations: library, local
        )

        let context = ModelContext(container)
        let item = Item(relativePath: "a.zip", title: "本", author: "著者")
        context.insert(item)
        context.insert(LocalCoverState(itemID: item.id, version: 1, bytes: 1234))
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Item>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LocalCoverState>()) == 1)
    }

    @MainActor
    @Test func distributionStaysOutOfItWhileTheLibraryIsNotShared() {
        // What decides who fetches what is coverVersion, and that only reaches
        // the other devices through iCloud. With syncing off there is no other
        // device in the picture, so neither direction has a job to do.
        let coordinator = ThumbnailDistributionCoordinator()

        #expect(!coordinator.isActive)
        #expect(coordinator.inactiveReason != nil)
        // Cover generation asks this before it opens an archive; nothing should
        // have pointed it at a folder.
        #expect(ThumbnailDistribution.currentRoot == nil)
    }
}
