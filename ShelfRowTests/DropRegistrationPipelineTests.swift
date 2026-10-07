import Foundation
import Testing
@testable import ShelfRow

struct DropRegistrationPipelineTests {
    @Test func providerLoadingPreservesFinderOrder() async {
        let urls = [
            URL(fileURLWithPath: "/tmp/first.zip"),
            URL(fileURLWithPath: "/tmp/second.zip"),
            URL(fileURLWithPath: "/tmp/third.zip")
        ]
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }

        let loaded = await DroppedFileProviderLoader.urls(from: providers)

        #expect(loaded == urls)
    }

    @Test func preflightPreservesOrderAndIdentifiesDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("pages", isDirectory: true)
        let archive = root.appendingPathComponent("book.zip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: archive)
        defer { try? FileManager.default.removeItem(at: root) }

        let facts = await DroppedFilePreflight.inspect(
            urls: [archive, folder],
            maximumConcurrentRequests: 2
        )

        #expect(facts.map(\.url) == [archive, folder])
        #expect(facts.map(\.exists) == [true, true])
        #expect(facts.map(\.isDirectory) == [false, true])
    }

    @MainActor
    @Test func registeredItemBecomesTheOnlySelectionAndRequestsReveal() {
        let state = LibrarySelectionState()
        let previous = UUID()
        let registered = UUID()
        state.itemID = previous
        state.itemIDs = [previous]

        state.selectRegisteredItem(registered)

        #expect(state.itemID == registered)
        #expect(state.itemIDs == [registered])
        #expect(state.anchorID == registered)
        #expect(state.consumePendingReveal(visibleIDs: [registered]) == registered)
        #expect(state.consumePendingReveal(visibleIDs: [registered]) == nil)
    }

    @MainActor
    @Test func registrationIndexReusesModelsAndTracksPathChanges() {
        let item = Item(relativePath: "old/book.zip", title: "Book")
        let index = LibraryRegistrationIndex()
        index.replace(models: [item.id: item], snapshots: [LibraryItemSnapshot(item)])

        #expect(index.itemsByPath["old/book.zip"] === item)

        item.relativePath = "new/book.zip"
        index.update(item, relativePath: item.relativePath)

        #expect(index.itemsByPath["old/book.zip"] == nil)
        #expect(index.itemsByPath["new/book.zip"] === item)
    }
}
