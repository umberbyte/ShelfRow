//
//  ShelfRowCLI.swift
//  ShelfRow
//

import AppKit
import Foundation
import OSLog
import SwiftData

/// The command line face of the app: list the shelves, and put a file on one
/// exactly as dropping it there would.
///
/// It is the same binary. A separate tool would need its own copy of the library
/// — the models, the settings, the rules about what a registered book is — and
/// the two would part ways. Running `ShelfRow.app/Contents/MacOS/ShelfRow` with
/// a command takes the command; with none, it opens the window as always.
///
/// Registering goes through the same three stages a drop does: ask the file
/// system what is there (`DroppedFilePreflight`), put it in the library
/// (`LibraryRegistrar`), then count the pages (`DroppedFilePageCounter`). What
/// differs is only where the files came from and that nobody is watching, so
/// the counting is awaited rather than left to follow.
enum ShelfRowCLI {
    private static let logger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "CLI")

    private static let commandNames: Set<String> = ["shelves", "add", "help"]

    /// Why a named shelf could not be used.
    enum ShelfLookupFailure: LocalizedError, Equatable {
        case notFound(String)
        case isSmart(String)
        case ambiguous(name: String, count: Int)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "シェルフが見つかりません: \(name)（shelves で一覧を確認できます）"
            case .isSmart(let name):
                return "「\(name)」はスマートシェルフです。条件で自動的に集まるため、手で追加することはできません。"
            case .ambiguous(let name, let count):
                return "「\(name)」という名前のシェルフが\(count)個あります。名前を変えて区別してください。"
            }
        }
    }

    enum Command: Equatable {
        case shelves
        case add(paths: [String], shelf: String?)
        case help
        case usageError(String)
    }

    /// Whether these arguments are a command rather than an app launch.
    ///
    /// Only a bare word this tool knows counts. Everything Xcode and
    /// LaunchServices pass begins with a dash, so a window launch is never
    /// mistaken for one.
    static func isCommandLine(_ arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first else { return false }
        return commandNames.contains(first) || first == "--help" || first == "-h"
    }

    static func parse(_ arguments: [String]) -> Command {
        var rest = Array(arguments.dropFirst())
        guard let verb = rest.first else { return .help }
        rest.removeFirst()

        switch verb {
        case "help", "--help", "-h":
            return .help

        case "shelves":
            guard rest.isEmpty else { return .usageError("shelves は引数を取りません: \(rest.joined(separator: " "))") }
            return .shelves

        case "add":
            var paths: [String] = []
            var shelf: String?
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                switch argument {
                case "--shelf", "-s":
                    guard index + 1 < rest.count else { return .usageError("--shelf にシェルフ名がありません。") }
                    shelf = rest[index + 1]
                    index += 2
                case let flag where flag.hasPrefix("-"):
                    return .usageError("知らない指定です: \(flag)")
                default:
                    paths.append(argument)
                    index += 1
                }
            }
            guard !paths.isEmpty else { return .usageError("追加するファイルを指定してください。") }
            return .add(paths: paths, shelf: shelf)

        default:
            return .usageError("知らないコマンドです: \(verb)")
        }
    }

    static let usage = """
        ShelfRow コマンドライン

        使い方:
          ShelfRow shelves                       シェルフの一覧を表示します
          ShelfRow add <ファイル>... [--shelf 名前]  ライブラリに登録します
                                                 --shelf を付けると、そのシェルフへ
                                                 ドラッグ&ドロップしたのと同じ動作になります

        例:
          /Applications/ShelfRow.app/Contents/MacOS/ShelfRow shelves
          /Applications/ShelfRow.app/Contents/MacOS/ShelfRow add /Volumes/Files/本/巻1.zip --shelf 未整理

        注意:
          ファイルは登録済みボリュームの中にある必要があります。アプリはサンドボックス
          の中で動いており、外のパスへは、ボリュームに保存されたアクセス権を通してしか
          手が届きません。新しい場所を登録するときは、アプリの画面へドラッグしてください。

          追加はアプリを終了してから実行してください。同じデータベースを2つのプロセスが
          同時に書くのを避けるためです。
        """

    // MARK: - Running

    @MainActor
    static func run(_ arguments: [String] = CommandLine.arguments) -> Int32 {
        switch parse(arguments) {
        case .help:
            write(usage)
            return 0

        case .usageError(let message):
            write(message, to: .standardError)
            write(usage, to: .standardError)
            return 64  // EX_USAGE

        case .shelves:
            return withLibrary(requiresExclusiveAccess: false) { context, _ in
                listShelves(context: context)
            }

        case .add(let paths, let shelf):
            return withLibrary(requiresExclusiveAccess: true) { context, vault in
                add(paths: paths, shelfName: shelf, context: context, vault: vault)
            }
        }
    }

    /// Opens the library the way the app does, minus iCloud.
    ///
    /// Mirroring is left out on purpose: this process lives for a moment, and
    /// starting a sync it cannot see through would be worse than leaving the
    /// change for the app to send the next time it runs. Core Data records what
    /// changed either way, so nothing is lost by waiting.
    @MainActor
    private static func withLibrary(
        requiresExclusiveAccess: Bool,
        perform work: (ModelContext, BookmarkVault) -> Int32
    ) -> Int32 {
        if requiresExclusiveAccess, isAppRunning() {
            write("ShelfRow が起動しています。終了してから実行してください。", to: .standardError)
            return 69  // EX_UNAVAILABLE
        }

        do {
            let directory = try StoreFileBackup.storeDirectory()
            let library = ModelConfiguration(
                "Library",
                schema: Schema(LibraryStore.libraryModels),
                url: directory.appendingPathComponent(StoreFileBackup.libraryStoreName),
                cloudKitDatabase: .none
            )
            let local = ModelConfiguration(
                "Local",
                schema: Schema(LibraryStore.localModels),
                url: directory.appendingPathComponent(StoreFileBackup.localStoreName),
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: Schema(LibraryStore.libraryModels + LibraryStore.localModels),
                configurations: library, local
            )

            storeDirectoryInUse = directory
            let vault = BookmarkVault()
            vault.attach(to: container)
            return work(container.mainContext, vault)
        } catch {
            write("蔵書データベースを開けませんでした: \(error.localizedDescription)", to: .standardError)
            return 74  // EX_IOERR
        }
    }

    /// Where the library was opened from, for the one message that needs to say
    /// so: an empty answer from the wrong store looks exactly like an empty
    /// library, and a sandboxed build and an unsandboxed one keep theirs in
    /// different places.
    @MainActor private static var storeDirectoryInUse: URL?

    private static func isAppRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != ownProcess && !$0.isTerminated }
    }

    // MARK: - shelves

    @MainActor
    private static func listShelves(context: ModelContext) -> Int32 {
        do {
            let shelves = try context.fetch(
                FetchDescriptor<Shelf>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.title)])
            )
            guard !shelves.isEmpty else {
                write("シェルフはありません。（読んだ蔵書: \(storeDirectoryInUse?.path ?? "不明")）")
                return 0
            }
            for shelf in shelves {
                write(describe(shelf))
            }
            return 0
        } catch {
            write("シェルフを読めませんでした: \(error.localizedDescription)", to: .standardError)
            return 74
        }
    }

    /// One shelf a line, name first, so the output can be piped through the
    /// ordinary tools without anything having to parse a layout.
    static func describe(_ shelf: Shelf) -> String {
        let kind = shelf.type == 0 ? "通常" : "スマート"
        return "\(shelf.title)\t\(kind)\t\(shelf.items?.count ?? 0)件"
    }

    // MARK: - add

    @MainActor
    private static func add(
        paths: [String],
        shelfName: String?,
        context: ModelContext,
        vault: BookmarkVault
    ) -> Int32 {
        var targetShelf: Shelf?
        if let shelfName {
            switch findShelf(named: shelfName, context: context) {
            case .success(let shelf):
                targetShelf = shelf
            case .failure(let failure):
                write(failure.localizedDescription, to: .standardError)
                return 65  // EX_DATAERR
            }
        }

        let registrar = LibraryRegistrar(context: context, vault: vault, settings: .fromDefaults())
        let index = LibraryRegistrationIndex()
        index.replace(
            models: Dictionary(
                ((try? context.fetch(FetchDescriptor<Item>())) ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            snapshots: []
        )
        var volumesByPath = Dictionary(
            ((try? context.fetch(FetchDescriptor<Volume>())) ?? []).map { ($0.lastKnownPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var failures = 0
        var pageCounts: [DroppedFilePageCountRequest] = []

        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

            // Access comes from the volume this file sits on, which the library
            // already holds permission for. A path alone grants this process
            // nothing: it is sandboxed, and nobody handed it the file. The scope
            // has to be open around the preflight too, which is where the file is
            // looked at and its own bookmark made.
            let access = VolumeAccess(url: url, volumesByPath: volumesByPath, vault: vault)
            defer { access.release() }

            let fact = DroppedFilePreflight.inspect(url: url)
            guard fact.exists else {
                let hint = access.isHeld ? "" : "（このファイルのあるボリュームは登録されていません。一度アプリの画面へドラッグしてください）"
                write("見つかりません: \(url.path)\(hint)", to: .standardError)
                failures += 1
                continue
            }
            guard let kind = registrar.kind(for: fact) else {
                write("登録の対象外です: \(url.lastPathComponent)（環境設定 > ヘルパーに拡張子を登録すると受け付けます）",
                      to: .standardError)
                failures += 1
                continue
            }

            let outcome = registrar.register(
                fact: fact,
                kind: kind,
                targetShelf: targetShelf,
                index: index,
                volumesByPath: &volumesByPath
            )
            if let request = outcome.pageCount {
                // Counted while the volume is still open, since the scope closes
                // when this file is done with.
                let update = DroppedFilePageCountUpdate(
                    itemID: request.itemID,
                    pageCount: ItemFileAccess.listPages(at: request.url).count,
                    shouldApplyAutoBookType: request.shouldApplyAutoBookType
                )
                registrar.apply(update, index: index)
                pageCounts.append(request)
            }

            let shelfNote = shelfName.map { "→ \($0)" } ?? ""
            write("\(outcome.isNew ? "登録" : "更新"): \(url.lastPathComponent) \(shelfNote)"
                .trimmingCharacters(in: .whitespaces))
        }

        do {
            vault.savePendingChanges()
            try context.save()
        } catch {
            write("保存できませんでした: \(error.localizedDescription)", to: .standardError)
            return 74
        }

        logger.info("""
            Registered \(paths.count - failures, privacy: .public) of \(paths.count, privacy: .public) files \
            from the command line, \(pageCounts.count, privacy: .public) of them counted
            """)
        return failures == 0 ? 0 : 65
    }

    /// Shelves are named by hand, so an exact match is tried first and a
    /// case-insensitive one after; two shelves of the same name is a question
    /// only the person can answer.
    private static func findShelf(named name: String, context: ModelContext) -> Result<Shelf, ShelfLookupFailure> {
        match(name: name, in: (try? context.fetch(FetchDescriptor<Shelf>())) ?? [])
    }

    /// The matching rule, kept apart from the store so it can be tried on its own.
    static func match(name: String, in shelves: [Shelf]) -> Result<Shelf, ShelfLookupFailure> {
        let ordinary = shelves.filter { $0.type == 0 }
        let exact = ordinary.filter { $0.title == name }
        let matches = exact.isEmpty
            ? ordinary.filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
            : exact

        switch matches.count {
        case 1:
            return .success(matches[0])
        case 0:
            let smart = shelves.contains {
                $0.type != 0 && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            return .failure(smart ? .isSmart(name) : .notFound(name))
        default:
            return .failure(.ambiguous(name: name, count: matches.count))
        }
    }

    /// Holds the security-scoped volume open for as long as one file needs it.
    @MainActor
    private struct VolumeAccess {
        private let scope: URL?
        var isHeld: Bool { scope != nil }

        init(url: URL, volumesByPath: [String: Volume], vault: BookmarkVault) {
            let (volumePath, _, _) = PathParser.split(url.path)
            guard let volume = volumesByPath[volumePath],
                  let bookmark = vault.bookmark(for: volume.id) else {
                scope = nil
                return
            }

            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() else {
                scope = nil
                return
            }
            scope = resolved
        }

        func release() {
            scope?.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Output

    /// Results go to the terminal, which is the point of the tool; the log is
    /// for what happened, not for what was asked.
    private enum Stream {
        case standardOutput
        case standardError

        var handle: FileHandle {
            switch self {
            case .standardOutput: return .standardOutput
            case .standardError: return .standardError
            }
        }
    }

    private static func write(_ text: String, to stream: Stream = .standardOutput) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        stream.handle.write(data)
    }
}
