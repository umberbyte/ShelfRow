import Foundation
import Testing
@testable import ShelfRow

struct ClientDataResetTests {
    @Test func removesApplicationSupportAndCacheContentsWithoutTouchingExternalData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientDataResetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let external = root.appendingPathComponent("ExternalBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        try Data("database".utf8).write(to: applicationSupport.appendingPathComponent("default.store"))
        let hiddenSupport = applicationSupport.appendingPathComponent(".default_SUPPORT", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenSupport, withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: hiddenSupport.appendingPathComponent("asset"))
        let thumbnails = caches.appendingPathComponent("com.eureka.ShelfRow/Thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: thumbnails.appendingPathComponent("cover.jpg"))
        let externalFile = external.appendingPathComponent("backup.zip")
        try Data("backup".utf8).write(to: externalFile)

        try ClientDataReset.clearContents(
            applicationSupportDirectory: applicationSupport,
            cachesDirectory: caches
        )

        #expect(try FileManager.default.contentsOfDirectory(atPath: applicationSupport.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: caches.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: externalFile.path))
    }
}
