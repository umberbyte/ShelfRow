//
//  ZipExtractor.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import Foundation
import Compression

/// Pure-Swift ZIP archive reader (central directory parser + raw deflate).
///
/// The previous implementation spawned `/usr/bin/unzip` as a child process,
/// but security-scoped file access is NOT inherited by child processes under
/// the App Sandbox, so archives on external volumes could not be read.
/// This implementation reads the archive in-process via FileHandle.
nonisolated struct ZipExtractor {

    struct Entry {
        let name: String
        let method: UInt16          // 0 = stored, 8 = deflate
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private final class EntryCacheBox {
        let signature: String
        let entries: [Entry]

        init(signature: String, entries: [Entry]) {
            self.signature = signature
            self.entries = entries
        }
    }

    private static let entryCache = NSCache<NSString, EntryCacheBox>()

    // MARK: - Public API

    /// Lists all file paths inside a ZIP archive (directories excluded).
    static func listFiles(at archiveURL: URL) -> [String] {
        readEntries(at: archiveURL)
            .filter { !$0.name.hasSuffix("/") && $0.uncompressedSize > 0 }
            .map { $0.name }
    }

    /// Extracts the raw bytes of a specific file from a ZIP archive.
    static func extractFile(archiveURL: URL, fileName: String) -> Data? {
        guard let entry = readEntries(at: archiveURL).first(where: { $0.name == fileName }) else {
            return nil
        }
        return extract(entry: entry, from: archiveURL)
    }

    // MARK: - Central directory parsing

    private static func readEntries(at url: URL) -> [Entry] {
        let cacheKey = url.path as NSString
        let currentSignature = archiveSignature(for: url)
        if let currentSignature,
           let cached = entryCache.object(forKey: cacheKey),
           cached.signature == currentSignature {
            return cached.entries
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { return [] }

        // 1. Find the End Of Central Directory record in the trailing bytes
        //    (22-byte fixed part + up to 64KB comment).
        let tailLength = Int(min(fileSize, 65557))
        guard let tail = read(handle, offset: fileSize - UInt64(tailLength), count: tailLength) else { return [] }

        var eocdIndex = -1
        var i = tailLength - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                eocdIndex = i
                break
            }
            i -= 1
        }
        guard eocdIndex >= 0 else { return [] }

        let eocd = tail.subdata(in: eocdIndex..<tailLength)
        var entryCount = UInt64(le16(eocd, 10))
        var cdSize = UInt64(le32(eocd, 12))
        var cdOffset = UInt64(le32(eocd, 16))

        // 2. ZIP64 support: sentinel values redirect to the ZIP64 EOCD record.
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let eocdAbsolute = fileSize - UInt64(tailLength) + UInt64(eocdIndex)
            if eocdAbsolute >= 20,
               let locator = read(handle, offset: eocdAbsolute - 20, count: 20),
               le32(locator, 0) == 0x0706_4B50 {
                let zip64Offset = le64(locator, 8)
                if let zip64 = read(handle, offset: zip64Offset, count: 56),
                   le32(zip64, 0) == 0x0606_4B50 {
                    entryCount = le64(zip64, 32)
                    cdSize = le64(zip64, 40)
                    cdOffset = le64(zip64, 48)
                }
            }
        }

        guard cdSize > 0, cdSize < 512 * 1024 * 1024,
              let cd = read(handle, offset: cdOffset, count: Int(cdSize)) else {
            return []
        }

        // 3. Walk the central directory records (signature PK\x01\x02).
        var entries: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, entries.count < entryCount {
            guard le32(cd, p) == 0x0201_4B50 else { break }

            let flags = le16(cd, p + 8)
            let method = le16(cd, p + 10)
            var compressedSize = UInt64(le32(cd, p + 20))
            var uncompressedSize = UInt64(le32(cd, p + 24))
            let nameLength = Int(le16(cd, p + 28))
            let extraLength = Int(le16(cd, p + 30))
            let commentLength = Int(le16(cd, p + 32))
            var localHeaderOffset = UInt64(le32(cd, p + 42))

            guard p + 46 + nameLength + extraLength + commentLength <= cd.count else { break }
            let nameData = cd.subdata(in: (p + 46)..<(p + 46 + nameLength))

            // ZIP64 extended information extra field (id 0x0001)
            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                var q = p + 46 + nameLength
                let extraEnd = q + extraLength
                while q + 4 <= extraEnd {
                    let fieldID = le16(cd, q)
                    let fieldSize = Int(le16(cd, q + 2))
                    if fieldID == 0x0001 {
                        var r = q + 4
                        let fieldEnd = q + 4 + fieldSize
                        if uncompressedSize == 0xFFFF_FFFF, r + 8 <= fieldEnd { uncompressedSize = le64(cd, r); r += 8 }
                        if compressedSize == 0xFFFF_FFFF, r + 8 <= fieldEnd { compressedSize = le64(cd, r); r += 8 }
                        if localHeaderOffset == 0xFFFF_FFFF, r + 8 <= fieldEnd { localHeaderOffset = le64(cd, r); r += 8 }
                        break
                    }
                    q += 4 + fieldSize
                }
            }

            let name = decodeName(nameData, utf8Flag: (flags & 0x0800) != 0)
            entries.append(Entry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            p += 46 + nameLength + extraLength + commentLength
        }
        if let currentSignature {
            entryCache.setObject(EntryCacheBox(signature: currentSignature, entries: entries), forKey: cacheKey)
        }
        return entries
    }

    private static func archiveSignature(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize else {
            return nil
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(fileSize)-\(modified)"
    }

    // MARK: - Entry extraction

    private static func extract(entry: Entry, from url: URL) -> Data? {
        // Sanity limit: covers even very large scanned images
        guard entry.uncompressedSize > 0, entry.uncompressedSize < 1_500_000_000 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Local file header (PK\x03\x04): name/extra lengths can differ from
        // the central directory, so re-read them here.
        guard let localHeader = read(handle, offset: entry.localHeaderOffset, count: 30),
              le32(localHeader, 0) == 0x0403_4B50 else {
            return nil
        }
        let nameLength = Int(le16(localHeader, 26))
        let extraLength = Int(le16(localHeader, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength + extraLength)

        guard let raw = read(handle, offset: dataOffset, count: Int(entry.compressedSize)) else { return nil }

        switch entry.method {
        case 0:  return raw // stored
        case 8:  return inflateRaw(raw, uncompressedSize: Int(entry.uncompressedSize))
        default: return nil // unsupported compression method
        }
    }

    /// Inflates a raw-deflate stream (ZIP method 8) using the Compression framework.
    private static func inflateRaw(_ data: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let sourcePtr = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: uncompressedSize)
            defer { destination.deallocate() }
            // COMPRESSION_ZLIB decodes raw deflate (no zlib header), matching ZIP.
            let written = compression_decode_buffer(destination, uncompressedSize, sourcePtr, data.count, nil, COMPRESSION_ZLIB)
            guard written == uncompressedSize else { return nil }
            return Data(bytes: destination, count: written)
        }
    }

    // MARK: - Byte helpers

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Decodes an entry file name. Classic Japanese archives (自炊ZIP) usually
    /// use Shift_JIS unless the UTF-8 flag (general purpose bit 11) is set.
    private static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if utf8Flag, let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .shiftJIS) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func le16(_ d: Data, _ i: Int) -> UInt16 {
        let b = d.startIndex + i
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }

    private static func le32(_ d: Data, _ i: Int) -> UInt32 {
        let b = d.startIndex + i
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }

    private static func le64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(le32(d, i)) | (UInt64(le32(d, i + 4)) << 32)
    }
}
