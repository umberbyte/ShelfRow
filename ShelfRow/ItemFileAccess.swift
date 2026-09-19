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

/// Applies ShelfRow's lightweight automatic book-type rules for newly added
/// ZIPs/folders. Non-book media types are intentionally not inferred here.
nonisolated enum BookTypeAutoClassifier {
    static func classify(pageCount: Int) -> Int? {
        switch pageCount {
        case 21...:
            return 0 // 厚い本
        case 11...20:
            return 1 // 薄い本
        case 1...10:
            return 2 // 本の一部
        default:
            return nil
        }
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

    struct ImageCharacteristics {
        let width: Int
        let height: Int
        let isMonochrome: Bool

        var isLandscape: Bool { width > height }
        var isPortrait: Bool { height > width }
    }

    /// Minimum member count for a file group to be trusted as 連番 (sequence).
    private static let minimumSequenceLength = 3

    static func bestCoverPage(from pages: [BookPage]) -> BookPage? {
        guard !pages.isEmpty else { return nil }
        return bestSequentialCoverPage(from: pages) ?? pages.first
    }

    /// Returns the first image in the largest numbered sequence, or nil when
    /// no trustworthy sequence exists.
    static func bestSequentialCoverPage(from pages: [BookPage]) -> BookPage? {
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

        return nil
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

    /// Selects cover image data for thumbnail repair/generation.
    ///
    /// Rule:
    /// 1. Use the first image in the largest numbered sequence.
    /// 2. If that image is monochrome, fallback to the first portrait,
    ///    non-monochrome image in name order.
    /// 3. If no trustworthy sequence exists, use the first portrait,
    ///    non-monochrome image in name order.
    static func preferredCoverData(bookURL: URL) -> Data? {
        let pages = ItemFileAccess.listPages(at: bookURL)
        if let sequenceFirst = bestSequentialCoverPage(from: pages),
           let sequenceData = ItemFileAccess.loadPageData(bookURL: bookURL, page: sequenceFirst),
           let sequenceCharacteristics = imageCharacteristics(from: sequenceData),
           !sequenceCharacteristics.isMonochrome {
            return sequenceData
        }

        for page in pages {
            guard let data = ItemFileAccess.loadPageData(bookURL: bookURL, page: page),
                  let characteristics = imageCharacteristics(from: data),
                  characteristics.isPortrait,
                  !characteristics.isMonochrome else {
                continue
            }
            return data
        }

        return nil
    }

    /// Reads the pixel dimensions of an image file without decoding it.
    static func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard imageFileLooksComplete(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    static func imageCharacteristics(at url: URL) -> ImageCharacteristics? {
        guard imageFileLooksComplete(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return imageCharacteristics(from: source)
    }

    static func imageIsMonochrome(at url: URL) -> Bool {
        guard imageFileLooksComplete(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return isMonochrome(source)
    }

    static func imageCharacteristics(from data: Data) -> ImageCharacteristics? {
        guard imageDataLooksComplete(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return imageCharacteristics(from: source)
    }

    /// Cheap container-level completeness checks to avoid handing obviously
    /// truncated images to ImageIO, which otherwise logs IIOScanner EOF warnings.
    static func imageDataLooksComplete(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(32))

        // JPEG: SOI ... EOI
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            return data.count >= 4 && data[data.index(data.endIndex, offsetBy: -2)] == 0xFF && data[data.index(before: data.endIndex)] == 0xD9
        }

        // PNG: signature ... IEND chunk trailer
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if bytes.starts(with: pngSignature) {
            let iendTrailer: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
            return data.count >= iendTrailer.count && data.suffix(iendTrailer.count).elementsEqual(iendTrailer)
        }

        // GIF: GIF87a/GIF89a ... trailer byte
        if bytes.count >= 6,
           (bytes.prefix(6).elementsEqual(Array("GIF87a".utf8)) || bytes.prefix(6).elementsEqual(Array("GIF89a".utf8))) {
            return data.last == 0x3B
        }

        // WebP: RIFF size WEBP. RIFF size excludes the first 8 bytes.
        if bytes.count >= 12,
           bytes[0...3].elementsEqual(Array("RIFF".utf8)),
           bytes[8...11].elementsEqual(Array("WEBP".utf8)) {
            let riffSize = Int(bytes[4]) | (Int(bytes[5]) << 8) | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 24)
            return riffSize >= 4 && riffSize + 8 <= data.count
        }

        // TIFF/BMP/HEIC and unknown formats are left to ImageIO; they are less
        // commonly the source of the noisy EOF warnings in this app's workflow.
        return true
    }

    static func imageFileLooksComplete(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize >= 4 else { return false }
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 32), !header.isEmpty else { return false }

        let tailLength = Int(min(fileSize, 16))
        try? handle.seek(toOffset: fileSize - UInt64(tailLength))
        let tail = (try? handle.read(upToCount: tailLength)) ?? Data()

        let probe = header + tail
        if probe.starts(with: Data([0xFF, 0xD8])) {
            return tail.count >= 2 && tail[tail.index(tail.endIndex, offsetBy: -2)] == 0xFF && tail[tail.index(before: tail.endIndex)] == 0xD9
        }

        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if probe.starts(with: pngSignature) {
            let iendTrailer = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
            return tail.suffix(iendTrailer.count).elementsEqual(iendTrailer)
        }

        if header.count >= 6,
           (header.prefix(6).elementsEqual(Data("GIF87a".utf8)) || header.prefix(6).elementsEqual(Data("GIF89a".utf8))) {
            return tail.last == 0x3B
        }

        if header.count >= 12,
           header.prefix(4).elementsEqual(Data("RIFF".utf8)),
           header.dropFirst(8).prefix(4).elementsEqual(Data("WEBP".utf8)) {
            let bytes = [UInt8](header.prefix(8))
            let riffSize = Int(bytes[4]) | (Int(bytes[5]) << 8) | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 24)
            return riffSize >= 4 && riffSize + 8 <= fileSize
        }

        return true
    }

    private static func imageCharacteristics(from source: CGImageSource) -> ImageCharacteristics? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return ImageCharacteristics(
            width: width,
            height: height,
            isMonochrome: isMonochrome(source)
        )
    }

    private static func isMonochrome(_ source: CGImageSource) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return false
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }

        var coloredPixels = 0
        var visiblePixels = 0
        let tolerance = 6
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 12 else { continue }
            visiblePixels += 1

            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let maxChannel = max(red, green, blue)
            let minChannel = min(red, green, blue)
            if maxChannel - minChannel > tolerance {
                coloredPixels += 1
            }
        }

        guard visiblePixels > 0 else { return false }
        return Double(coloredPixels) / Double(visiblePixels) < 0.01
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
        var keywordA = ""
        var keywordB = ""
        var relation = ""
        var type = ""
    }

    static func parse(fileName: String) -> ParsedName {
        parseClassic(fileName: fileName)
    }

    static func parse(fileName: String, format: String) -> ParsedName {
        if let parsed = parseWithFormat(fileName: fileName, format: format) {
            return parsed
        }
        return parseClassic(fileName: fileName)
    }

    private static func parseClassic(fileName: String) -> ParsedName {
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

    private static func parseWithFormat(fileName: String, format: String) -> ParsedName? {
        let format = format.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !format.isEmpty else { return nil }

        let placeholders = ["@keywordA", "@keywordB", "@relation", "@author", "@title", "@genre", "@type"]
        var regex = "^"
        var captures: [String] = []
        var index = format.startIndex

        while index < format.endIndex {
            if let placeholder = placeholders.first(where: { format[index...].hasPrefix($0) }) {
                let remaining = String(format[format.index(index, offsetBy: placeholder.count)..<format.endIndex])
                let hasFollowingLiteral = placeholders.contains { remaining.contains($0) } || !remaining.isEmpty
                regex += hasFollowingLiteral ? "(.+?)" : "(.+)"
                captures.append(placeholder)
                index = format.index(index, offsetBy: placeholder.count)
            } else {
                let start = index
                repeat {
                    index = format.index(after: index)
                } while index < format.endIndex && !placeholders.contains(where: { format[index...].hasPrefix($0) })
                regex += escapedLiteralPattern(String(format[start..<index]))
            }
        }

        regex += "$"
        guard !captures.isEmpty,
              let expression = try? NSRegularExpression(pattern: regex) else {
            return nil
        }

        let baseName = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(baseName.startIndex..<baseName.endIndex, in: baseName)
        guard let match = expression.firstMatch(in: baseName, range: range),
              match.numberOfRanges == captures.count + 1 else {
            return nil
        }

        var result = ParsedName()
        for (offset, placeholder) in captures.enumerated() {
            let valueRange = match.range(at: offset + 1)
            guard let swiftRange = Range(valueRange, in: baseName) else { continue }
            let value = String(baseName[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch placeholder {
            case "@author": result.author = value
            case "@title": result.title = stripTrailingSquareGroups(value)
            case "@keywordA": result.keywordA = value
            case "@keywordB": result.keywordB = value
            case "@relation": result.relation = value
            case "@genre": result.genre = value
            case "@type": result.type = value
            default: break
            }
        }

        return result
    }

    private static func escapedLiteralPattern(_ literal: String) -> String {
        var pattern = ""
        var whitespaceOpen = false
        var hasNonWhitespace = false
        for scalar in literal.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                whitespaceOpen = true
                continue
            }
            if whitespaceOpen {
                pattern += "\\s*"
                whitespaceOpen = false
            }
            hasNonWhitespace = true
            pattern += NSRegularExpression.escapedPattern(for: String(scalar))
        }
        if whitespaceOpen {
            // Pure-whitespace separator between two placeholders must require at
            // least one space so that lazy captures match whole tokens (e.g. "#青")
            // rather than stopping at the first character (e.g. "#").
            pattern += hasNonWhitespace ? "\\s*" : "\\s+"
        }
        return pattern
    }

    private static func stripTrailingSquareGroups(_ value: String) -> String {
        var title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasSuffix("]"), let openIndex = trailingGroupOpenIndex(title, open: "[", close: "]"),
              openIndex > title.startIndex {
            title = String(title[..<openIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
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
        let vault = BookmarkVault.shared

        // 1. Item-level bookmark: points directly at the file itself
        if let bookmark = vault.bookmark(for: item.id) {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
               resolved.startAccessingSecurityScopedResource() {
                if isStale,
                   let refreshed = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    // Refresh the stale bookmark while we still have access
                    vault.setBookmark(refreshed, for: item.id)
                }
                return ResolvedItemFile(url: resolved, securityAnchor: resolved)
            }
        }

        // 2. Volume-level bookmark + relative path
        guard let volume = item.volume else { return nil }

        var volumeURL = URL(fileURLWithPath: volume.lastKnownPath)
        var anchor: URL? = nil

        if let bookmark = vault.bookmark(for: volume.id) {
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
