//
//  ItemFileAccess.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import ImageIO

/// A resolved on-disk location for an Item, retaining the security-scoped
/// anchor URL so the caller can release access when finished.
struct ResolvedItemFile {
    let url: URL
    let securityAnchor: URL?

    /// Stops accessing the security-scoped resource if one was started.
    func release() {
        securityAnchor?.stopAccessingSecurityScopedResource()
    }
}

/// A single displayable page inside a book (ZIP entry or file in a folder).
nonisolated struct BookPage: Identifiable, Hashable {
    let id: Int          // page index
    let name: String     // entry name (zip) or file name (folder)
}

/// Splits an absolute path into (volume mount path, volume name, relative path).
/// Shared by the XML importer, drag & drop registration and alias restore.
nonisolated enum PathParser {
    static func split(_ path: String) -> (volumePath: String, volumeName: String, relativePath: String) {
        if path.hasPrefix("/Volumes/") {
            let components = path.components(separatedBy: "/")
            if components.count >= 3 {
                let volumeName = components[2]
                return ("/Volumes/\(volumeName)", volumeName, components[3...].joined(separator: "/"))
            }
        }
        let cleanedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return ("/", "Boot Volume", cleanedPath)
    }
}

/// Returns the customized name if set, otherwise the classic default label.
@inline(__always)
nonisolated func customName(_ value: String, default defaultName: String) -> String {
    value.isEmpty ? defaultName : value
}

/// Chooses the best cover page from a book's image list.
///
/// Scanned books typically contain a sequentially-numbered file group
/// (001.jpg, 002.jpg, ...) plus unrelated extras (event flyers, info images).
/// The cover should be the lowest number of the largest sequential group;
/// a simple alphabetical-first pick can grab a garbage image instead.
nonisolated enum CoverSelector {

    /// Minimum member count for a file group to be trusted as 連番 (sequence).
    private static let minimumSequenceLength = 3

    static func bestCoverPage(from pages: [BookPage]) -> BookPage? {
        guard !pages.isEmpty else { return nil }

        struct NumberedPage {
            let page: BookPage
            let number: Int
        }

        // Group files whose names differ only in their (last) numeric run.
        var groups: [String: [NumberedPage]] = [:]
        for page in pages {
            let fileName = (page.name as NSString).lastPathComponent
            let base = (fileName as NSString).deletingPathExtension
            guard let (number, template) = lastNumberAndTemplate(in: base) else { continue }

            let directory = (page.name as NSString).deletingLastPathComponent
            let ext = (fileName as NSString).pathExtension
            let key = "\(directory)|\(template)|\(ext)".lowercased()
            groups[key, default: []].append(NumberedPage(page: page, number: number))
        }

        // Pick the largest sequential group; its smallest number is the cover.
        let sequences = groups.values.filter { $0.count >= minimumSequenceLength }
        if let largest = sequences.max(by: { $0.count < $1.count }) {
            return largest.min {
                ($0.number, $0.page.name) < ($1.number, $1.page.name)
            }?.page
        }

        // Fallback: first image in name order (pages are pre-sorted)
        return pages.first
    }

    /// Extracts the last numeric run in a file base name, returning its value
    /// and a template with the run replaced by "#" (padding-insensitive).
    /// e.g. "img_005a" -> (5, "img_#a")
    private static func lastNumberAndTemplate(in name: String) -> (Int, String)? {
        let chars = Array(name)
        var end = chars.count - 1
        while end >= 0, !chars[end].isWholeNumber { end -= 1 }
        guard end >= 0 else { return nil }

        var start = end
        while start > 0, chars[start - 1].isWholeNumber { start -= 1 }

        guard let number = Int(String(chars[start...end])) else { return nil }
        let template = String(chars[..<start]) + "#" + String(chars[(end + 1)...])
        return (number, template)
    }

    /// Returns cover candidates in best-first order: the sequence-heuristic
    /// winner first, then the remaining pages in name order. Callers should
    /// try candidates until one decodes successfully (corrupt image fallback).
    static func orderedCoverCandidates(from pages: [BookPage], limit: Int = 8) -> [BookPage] {
        guard !pages.isEmpty else { return [] }
        var ordered: [BookPage] = []
        if let best = bestCoverPage(from: pages) {
            ordered.append(best)
        }
        for page in pages where !ordered.contains(page) {
            if ordered.count >= limit { break }
            ordered.append(page)
        }
        return ordered
    }

    /// Reads the pixel dimensions of an image file without decoding it.
    static func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}

/// Parses scanned-book file names of the form 「(ジャンル)[作者名]タイトル.zip」.
///
/// Rules:
/// - Leading `(...)` groups: only the FIRST is adopted as genre, others ignored.
/// - Leading `[...]` group: the FIRST is the author (may contain parentheses).
/// - Trailing `[...]` groups (e.g. [DL版]) are stripped from the title.
nonisolated enum FileNameParser {
    struct ParsedName {
        var genre = ""
        var author = ""
        var title = ""
    }

    static func parse(fileName: String) -> ParsedName {
        var rest = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
        var result = ParsedName()

        // 1. Leading (ジャンル) groups: adopt only the first, skip the rest
        while rest.hasPrefix("("), let (content, remainder) = takeLeadingGroup(rest, open: "(", close: ")") {
            if result.genre.isEmpty { result.genre = content }
            rest = remainder
        }

        // 2. Leading [作者名]: adopt only the first (may contain parentheses)
        while rest.hasPrefix("["), let (content, remainder) = takeLeadingGroup(rest, open: "[", close: "]") {
            if result.author.isEmpty { result.author = content }
            rest = remainder
        }

        // Occasionally the genre follows the author brackets instead
        while rest.hasPrefix("("), let (content, remainder) = takeLeadingGroup(rest, open: "(", close: ")") {
            if result.genre.isEmpty { result.genre = content }
            rest = remainder
        }

        // 3. Title = remainder with trailing [...] groups stripped
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("]"), let openIndex = trailingGroupOpenIndex(title, open: "[", close: "]"),
              openIndex > title.startIndex {
            title = String(title[..<openIndex]).trimmingCharacters(in: .whitespaces)
        }

        result.title = title
        result.genre = result.genre.trimmingCharacters(in: .whitespaces)
        result.author = result.author.trimmingCharacters(in: .whitespaces)
        return result
    }

    /// Consumes a balanced leading group like "(...)" and returns
    /// (content, trimmed remainder).
    private static func takeLeadingGroup(_ s: String, open: Character, close: Character) -> (String, String)? {
        guard s.first == open else { return nil }
        var depth = 0
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 {
                    let content = String(s[s.index(after: s.startIndex)..<idx])
                    let remainder = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    return (content, remainder)
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    /// Finds the opening index of a balanced group that ends at the last character.
    private static func trailingGroupOpenIndex(_ s: String, open: Character, close: Character) -> String.Index? {
        guard s.last == close else { return nil }
        var depth = 0
        var idx = s.index(before: s.endIndex)
        while true {
            let c = s[idx]
            if c == close {
                depth += 1
            } else if c == open {
                depth -= 1
                if depth == 0 { return idx }
            }
            if idx == s.startIndex { break }
            idx = s.index(before: idx)
        }
        return nil
    }
}

/// Shared helpers to resolve Item file locations and enumerate their images.
nonisolated enum ItemFileAccess {

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "heic"]

    /// Resolves the absolute file URL for an Item, starting security-scoped
    /// access when a bookmark is available. The item-level bookmark
    /// (drag & drop registration) takes precedence over the volume bookmark.
    @MainActor
    static func resolve(item: Item) -> ResolvedItemFile? {
        // 1. Item-level bookmark: points directly at the file itself
        if let bookmark = item.bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
               resolved.startAccessingSecurityScopedResource() {
                if isStale {
                    // Refresh the stale bookmark while we still have access
                    item.bookmarkData = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                return ResolvedItemFile(url: resolved, securityAnchor: resolved)
            }
        }

        // 2. Volume-level bookmark + relative path
        guard let volume = item.volume else { return nil }

        var volumeURL = URL(fileURLWithPath: volume.lastKnownPath)
        var anchor: URL? = nil

        if let bookmark = volume.bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                if resolved.startAccessingSecurityScopedResource() {
                    anchor = resolved
                }
                volumeURL = resolved
            }
        }

        return ResolvedItemFile(url: volumeURL.appendingPathComponent(item.relativePath), securityAnchor: anchor)
    }

    private static func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let base = (name as NSString).lastPathComponent
        return imageExtensions.contains(ext) && !name.contains("__MACOSX") && !base.hasPrefix(".")
    }

    /// Lists image pages inside a ZIP archive or an image folder, sorted by name.
    static func listPages(at url: URL) -> [BookPage] {
        let names: [String]
        if url.pathExtension.lowercased() == "zip" {
            names = ZipExtractor.listFiles(at: url).filter { isImageFile($0) }.sorted()
        } else {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return []
            }
            names = files.filter { isImageFile($0) }.sorted()
        }
        return names.enumerated().map { BookPage(id: $0.offset, name: $0.element) }
    }

    /// Loads the raw image data for a page of a book (ZIP entry or folder file).
    static func loadPageData(bookURL: URL, page: BookPage) -> Data? {
        if bookURL.pathExtension.lowercased() == "zip" {
            return ZipExtractor.extractFile(archiveURL: bookURL, fileName: page.name)
        }
        return try? Data(contentsOf: bookURL.appendingPathComponent(page.name))
    }
}
