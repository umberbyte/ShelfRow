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
            at: directory.appendingPathComponent("absent.jpg"),
            alreadyGenerated: false,
            knownToHaveNoCover: false
        ))

        #expect(reasons.isMissing)
        #expect(!reasons.isLandscape)
        #expect(!reasons.isMonochrome)
    }

    @Test func bulkGenerationRegeneratesAThumbnailItGeneratedIfTheFileIsGone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reasons = try #require(ContentView.thumbnailRepairReasons(
            at: directory.appendingPathComponent("absent.jpg"),
            alreadyGenerated: true,
            knownToHaveNoCover: false
        ))

        #expect(reasons.isMissing)
    }

    @Test func bulkGenerationTargetsAnEmptyThumbnailFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("truncated.jpg")
        try Data().write(to: thumbURL)

        let reasons = try #require(ContentView.thumbnailRepairReasons(at: thumbURL, alreadyGenerated: false, knownToHaveNoCover: false))

        #expect(reasons.isMissing)
    }

    @Test func bulkGenerationRepicksALandscapeThumbnailThatIsAlreadyOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("landscape.jpg")
        try makeTestImage(width: 80, height: 40, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1), type: .jpeg)
            .write(to: thumbURL)

        let reasons = try #require(ContentView.thumbnailRepairReasons(at: thumbURL, alreadyGenerated: false, knownToHaveNoCover: false))

        #expect(reasons.isLandscape)
        #expect(!reasons.isMissing)
    }

    @Test func coverExtractionStoreKeepsTheLatestOutcomePerBook() async throws {
        let store = try makeCoverExtractionStore()
        let generated = UUID()
        let hopeless = UUID()

        await store.record(generated: [generated], withoutCover: [hopeless])
        var states = await store.states()
        #expect(states.generated == [generated])
        #expect(states.withoutCover == [hopeless])

        // The book that had nothing usable now has a cover: it must stop counting
        // as one without a cover, rather than appearing in both.
        await store.record(generated: [hopeless], withoutCover: [])
        states = await store.states()
        #expect(states.generated == [generated, hopeless])
        #expect(states.withoutCover.isEmpty)
    }

    @Test func coverExtractionStoreForgetsBooksNoLongerInTheLibrary() async throws {
        let store = try makeCoverExtractionStore()
        let kept = UUID()
        let deleted = UUID()

        await store.record(generated: [kept, deleted], withoutCover: [])
        await store.prune(keeping: [kept])

        let states = await store.states()
        #expect(states.generated == [kept])
    }

    private func makeCoverExtractionStore() throws -> CoverExtractionStore {
        let container = try ModelContainer(
            for: CoverExtractionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return CoverExtractionStore(modelContainer: container)
    }

    @Test func bulkGenerationStopsRetryingABookWithNoUsableCover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Opening the book produced no thumbnail, so there is no file — but the
        // reason is inside the book, and a second run would find the same thing.
        #expect(ContentView.thumbnailRepairReasons(
            at: directory.appendingPathComponent("absent.jpg"),
            alreadyGenerated: false,
            knownToHaveNoCover: true
        ) == nil)
    }

    @Test func bulkGenerationLeavesACoverItAlreadyExtractedAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A book whose best page really is a spread, or is monochrome throughout:
        // re-extracting produces this same image, so a second run must not pick it
        // up again.
        let spread = directory.appendingPathComponent("landscape.jpg")
        try makeTestImage(width: 80, height: 40, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1), type: .jpeg)
            .write(to: spread)
        let monochrome = directory.appendingPathComponent("monochrome.png")
        try makeTestImage(width: 40, height: 80, color: CGColor(gray: 0.5, alpha: 1), type: .png)
            .write(to: monochrome)

        #expect(ContentView.thumbnailRepairReasons(at: spread, alreadyGenerated: true, knownToHaveNoCover: false) == nil)
        #expect(ContentView.thumbnailRepairReasons(at: monochrome, alreadyGenerated: true, knownToHaveNoCover: false) == nil)
    }

    @Test func bulkGenerationRepicksAMonochromeThumbnailThatIsAlreadyOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thumbURL = directory.appendingPathComponent("monochrome.png")
        try makeTestImage(width: 40, height: 80, color: CGColor(gray: 0.5, alpha: 1), type: .png)
            .write(to: thumbURL)

        let reasons = try #require(ContentView.thumbnailRepairReasons(at: thumbURL, alreadyGenerated: false, knownToHaveNoCover: false))

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

        #expect(ContentView.thumbnailRepairReasons(at: thumbURL, alreadyGenerated: false, knownToHaveNoCover: false) == nil)
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
