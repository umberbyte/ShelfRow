//
//  ShelfRowCLITests.swift
//  ShelfRowTests
//

import Foundation
import SwiftData
import Testing
@testable import ShelfRow

/// The command line face of the app.
struct ShelfRowCLITests {

    // MARK: - Telling a command from a launch

    @Test func onlyAKnownWordMakesThisACommandLine() {
        #expect(ShelfRowCLI.isCommandLine(["ShelfRow", "shelves"]))
        #expect(ShelfRowCLI.isCommandLine(["ShelfRow", "add", "/tmp/a.zip"]))
        #expect(ShelfRowCLI.isCommandLine(["ShelfRow", "--help"]))
    }

    @Test func anOrdinaryLaunchIsLeftAlone() {
        // What Xcode and LaunchServices add. Taking any of these for a command
        // would mean the app silently failing to open.
        #expect(!ShelfRowCLI.isCommandLine(["ShelfRow"]))
        #expect(!ShelfRowCLI.isCommandLine(["ShelfRow", "-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!ShelfRowCLI.isCommandLine(["ShelfRow", "-psn_0_123456"]))
    }

    // MARK: - Reading the arguments

    @Test func addTakesFilesAndAnOptionalShelf() {
        #expect(ShelfRowCLI.parse(["ShelfRow", "add", "/tmp/a.zip"]) == .add(paths: ["/tmp/a.zip"], shelf: nil))
        #expect(ShelfRowCLI.parse(["ShelfRow", "add", "/tmp/a.zip", "--shelf", "未整理"])
                == .add(paths: ["/tmp/a.zip"], shelf: "未整理"))
        #expect(ShelfRowCLI.parse(["ShelfRow", "add", "-s", "棚", "/tmp/a.zip", "/tmp/b.zip"])
                == .add(paths: ["/tmp/a.zip", "/tmp/b.zip"], shelf: "棚"))
    }

    @Test func aShelfNameThatLooksLikeAFlagIsStillATaken() {
        // Names are the person's own words; only the position decides.
        #expect(ShelfRowCLI.parse(["ShelfRow", "add", "/tmp/a.zip", "--shelf", "-s"])
                == .add(paths: ["/tmp/a.zip"], shelf: "-s"))
    }

    @Test func whatCannotBeActedOnIsSaidRatherThanGuessedAt() {
        guard case .usageError = ShelfRowCLI.parse(["ShelfRow", "add"]) else {
            Issue.record("adding nothing should be refused")
            return
        }
        guard case .usageError = ShelfRowCLI.parse(["ShelfRow", "add", "/tmp/a.zip", "--shelf"]) else {
            Issue.record("a shelf flag with no name should be refused")
            return
        }
        guard case .usageError = ShelfRowCLI.parse(["ShelfRow", "add", "--wat", "/tmp/a.zip"]) else {
            Issue.record("an unknown flag should be refused rather than taken for a path")
            return
        }
        guard case .usageError = ShelfRowCLI.parse(["ShelfRow", "shelves", "extra"]) else {
            Issue.record("shelves takes no arguments")
            return
        }
        #expect(ShelfRowCLI.parse(["ShelfRow", "help"]) == .help)
    }

    // MARK: - Finding the shelf that was named

    @Test func aShelfIsFoundByItsNameAndThenByItsSpelling() {
        let exact = Shelf(title: "未整理", icon: 0, type: 0)
        let other = Shelf(title: "Manga", icon: 0, type: 0)

        guard case .success(let found) = ShelfRowCLI.match(name: "未整理", in: [other, exact]) else {
            Issue.record("the shelf named should be the shelf found")
            return
        }
        #expect(found.id == exact.id)

        guard case .success(let insensitive) = ShelfRowCLI.match(name: "manga", in: [other, exact]) else {
            Issue.record("a name typed in another case should still find it")
            return
        }
        #expect(insensitive.id == other.id)
    }

    @Test func aSmartShelfSaysWhyItCannotBeAddedTo() {
        let smart = Shelf(title: "未読", icon: 0, type: 1)
        #expect(ShelfRowCLI.match(name: "未読", in: [smart]) == .failure(.isSmart("未読")))
    }

    @Test func aNameThatMatchesNothingAndOneThatMatchesTwiceAreDifferentProblems() {
        let a = Shelf(title: "棚", icon: 0, type: 0)
        let b = Shelf(title: "棚", icon: 0, type: 0)

        #expect(ShelfRowCLI.match(name: "無い棚", in: [a]) == .failure(.notFound("無い棚")))
        #expect(ShelfRowCLI.match(name: "棚", in: [a, b]) == .failure(.ambiguous(name: "棚", count: 2)))
    }

    @Test func anExactNameWinsOverOneThatOnlyMatchesInAnotherCase() {
        let exact = Shelf(title: "Manga", icon: 0, type: 0)
        let nearly = Shelf(title: "manga", icon: 0, type: 0)

        guard case .success(let found) = ShelfRowCLI.match(name: "Manga", in: [nearly, exact]) else {
            Issue.record("two shelves differing only in case should not be ambiguous when one matches exactly")
            return
        }
        #expect(found.id == exact.id)
    }

    // MARK: - Listing

    @Test func eachShelfIsOneLineOfPlainFields() {
        let shelf = Shelf(title: "未整理", icon: 0, type: 0)
        let line = ShelfRowCLI.describe(shelf)

        #expect(line.hasPrefix("未整理\t"))
        #expect(line.contains("通常"))
        #expect(line.contains("0件"))
        #expect(!line.contains("\n"))
    }
}

/// Putting a file into the library — the work a drop does, without the drop.
@MainActor
struct LibraryRegistrarTests {

    private func makeLibrary() throws -> ModelContainer {
        let schema = Schema(LibraryStore.libraryModels + LibraryStore.localModels)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private func makeRegistrar(_ container: ModelContainer) -> LibraryRegistrar {
        let vault = BookmarkVault()
        vault.attach(to: container)
        return LibraryRegistrar(
            context: container.mainContext,
            vault: vault,
            settings: LibraryRegistrar.Settings(
                renameFormat: "[@author] @title",
                typeNames: ["厚い本", "薄い本", "本の一部", "画像セット", "テキスト", "ムービー"],
                helperExtensions: ["zip", "mov"]
            )
        )
    }

    @Test func aFileBecomesABookOnTheShelfItWasGiven() throws {
        let container = try makeLibrary()
        let context = container.mainContext
        let registrar = makeRegistrar(container)

        let shelf = Shelf(title: "未整理", icon: 0, type: 0)
        context.insert(shelf)

        var items: [String: Item] = [:]
        var volumes: [String: Volume] = [:]
        let outcome = registrar.register(
            url: URL(fileURLWithPath: "/Volumes/Files/本/[作者] 題名.zip"),
            kind: .pageCountedArchive,
            targetShelfID: shelf.id,
            itemsByPath: &items,
            volumesByPath: &volumes
        )

        #expect(outcome.isNew)
        let registered = try context.fetch(FetchDescriptor<Item>())
        #expect(registered.count == 1)
        #expect(registered.first?.title == "題名")
        #expect(registered.first?.author == "作者")
        #expect(registered.first?.relativePath == "本/[作者] 題名.zip")
        #expect(shelf.items?.count == 1)

        // The volume is made once and then reused, which is what keeps a drop of
        // a thousand files from making a thousand of them.
        #expect(try context.fetch(FetchDescriptor<Volume>()).count == 1)
        #expect(volumes["/Volumes/Files"] != nil)
    }

    @Test func thesameFileTwiceIsOneBook() throws {
        let container = try makeLibrary()
        let context = container.mainContext
        let registrar = makeRegistrar(container)

        let shelf = Shelf(title: "未整理", icon: 0, type: 0)
        context.insert(shelf)
        let url = URL(fileURLWithPath: "/Volumes/Files/本/巻1.zip")

        var items: [String: Item] = [:]
        var volumes: [String: Volume] = [:]
        let first = registrar.register(url: url, kind: .pageCountedArchive, targetShelfID: shelf.id,
                                       itemsByPath: &items, volumesByPath: &volumes)
        let second = registrar.register(url: url, kind: .pageCountedArchive, targetShelfID: shelf.id,
                                        itemsByPath: &items, volumesByPath: &volumes)

        #expect(first.isNew)
        #expect(!second.isNew)
        #expect(first.itemID == second.itemID)
        #expect(try context.fetch(FetchDescriptor<Item>()).count == 1)
        // And it is on the shelf once, not twice.
        #expect(shelf.items?.count == 1)
    }

    @Test func aSmartShelfIsNeverAddedToByHand() throws {
        let container = try makeLibrary()
        let context = container.mainContext
        let registrar = makeRegistrar(container)

        let smart = Shelf(title: "未読", icon: 0, type: 1)
        context.insert(smart)

        var items: [String: Item] = [:]
        var volumes: [String: Volume] = [:]
        registrar.register(
            url: URL(fileURLWithPath: "/Volumes/Files/本/巻1.zip"),
            kind: .pageCountedArchive,
            targetShelfID: smart.id,
            itemsByPath: &items,
            volumesByPath: &volumes
        )

        #expect(try context.fetch(FetchDescriptor<Item>()).count == 1)
        #expect(smart.items?.isEmpty ?? true)
    }

    @Test func whatTheLibraryTakesDependsOnTheHelperSettings() throws {
        let container = try makeLibrary()
        let registrar = makeRegistrar(container)

        #expect(registrar.kind(for: URL(fileURLWithPath: "/a/b"), isDirectory: true) == .folder)
        #expect(registrar.kind(for: URL(fileURLWithPath: "/a/b.zip"), isDirectory: false) == .pageCountedArchive)
        #expect(registrar.kind(for: URL(fileURLWithPath: "/a/b.MOV"), isDirectory: false) == .helperFile)
        // Not registered as a helper, so it is not something to take in.
        #expect(registrar.kind(for: URL(fileURLWithPath: "/a/b.txt"), isDirectory: false) == nil)
        // An archive nobody registered is still not taken: rar and 7z arrive only
        // through the helper list.
        #expect(registrar.kind(for: URL(fileURLWithPath: "/a/b.rar"), isDirectory: false) == nil)
    }

    @Test func theHelperListIsReadAsPeopleWriteIt() {
        let extensions = LibraryRegistrar.Settings.extensions(in: " MOV, .avi ,mpg\nrar,zip , 7z\n\n")
        #expect(extensions == ["mov", "avi", "mpg", "rar", "zip", "7z"])
    }

    @Test func thePageCountSettlesTheTypeOnlyWhenTheNameDidNot() throws {
        let container = try makeLibrary()
        let context = container.mainContext
        let registrar = makeRegistrar(container)

        var items: [String: Item] = [:]
        var volumes: [String: Volume] = [:]
        let outcome = registrar.register(
            url: URL(fileURLWithPath: "/Volumes/Files/本/巻1.zip"),
            kind: .pageCountedArchive,
            targetShelfID: nil,
            itemsByPath: &items,
            volumesByPath: &volumes
        )
        #expect(outcome.shouldApplyAutoBookType)

        registrar.applyPageCount(120, to: outcome.itemID, applyingAutoBookType: true)
        let item = try #require(try context.fetch(FetchDescriptor<Item>()).first)
        #expect(item.pages == 120)
        #expect(item.bookType == BookTypeAutoClassifier.classify(pageCount: 120))
    }
}
