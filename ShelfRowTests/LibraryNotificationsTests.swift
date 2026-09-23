import Combine
import CoreData
import Foundation
import SwiftData
import Testing
@testable import ShelfRow

@MainActor
struct LibraryNotificationsTests {
    nonisolated private static func expectBackgroundThread() {
        #expect(!Thread.isMainThread)
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundSaveIsDeliveredOnMainWithoutPassingItsContext() async throws {
        let container = try ModelContainer(
            for: Schema(LibraryStore.libraryModels + LibraryStore.localModels),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let center = NotificationCenter()
        let stream = AsyncStream<(Bool, LibrarySaveEvent)>.makeStream()
        let subscription = LibraryNotifications.modelSaves(center: center).sink { event in
            stream.continuation.yield((Thread.isMainThread, event))
        }
        defer { subscription.cancel(); stream.continuation.finish() }

        let contextID = await Task.detached {
            let context = ModelContext(container)
            Self.expectBackgroundThread()
            center.post(name: ModelContext.didSave, object: context)
            return ObjectIdentifier(context)
        }.value
        var iterator = stream.stream.makeAsyncIterator()
        let received = await iterator.next()
        let (onMain, event) = try #require(received)
        #expect(onMain)
        #expect(event.contextID == contextID)
        #expect(event.containerID == ObjectIdentifier(container))
        #expect(event.inserted.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteChangeFromBackgroundIsDeliveredOnMain() async throws {
        let center = NotificationCenter()
        let stream = AsyncStream<Bool>.makeStream()
        let subscription = LibraryNotifications.remoteChanges(center: center).sink {
            stream.continuation.yield(Thread.isMainThread)
        }
        defer { subscription.cancel(); stream.continuation.finish() }
        await Task.detached {
            Self.expectBackgroundThread()
            center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        }.value
        var iterator = stream.stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteChangeBurstIsCoalescedBeforeRefreshingTheUI() async throws {
        let center = NotificationCenter()
        var deliveries = 0
        let stream = AsyncStream<Void>.makeStream()
        let subscription = LibraryNotifications.remoteChanges(center: center).sink {
            deliveries += 1
            stream.continuation.yield()
        }
        defer { subscription.cancel(); stream.continuation.finish() }

        center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        center.post(name: .NSPersistentStoreRemoteChange, object: nil)
        var iterator = stream.stream.makeAsyncIterator()
        _ = await iterator.next()
        try await Task.sleep(for: .milliseconds(400))

        #expect(deliveries == 1)
    }

    @Test func saveSnapshotKeepsIdentifierSetsAndArrays() throws {
        let container = try ModelContainer(
            for: Schema(LibraryStore.libraryModels + LibraryStore.localModels),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = container.mainContext
        let item = Item(relativePath: "test.zip", title: "Test")
        context.insert(item)
        try context.save()
        let id = item.persistentModelID
        let event = try #require(LibrarySaveEvent(Notification(
            name: ModelContext.didSave, object: context,
            userInfo: [ModelContext.NotificationKey.insertedIdentifiers: Set([id]),
                       ModelContext.NotificationKey.updatedIdentifiers.rawValue: [id]]
        )))
        #expect(event.inserted == [id])
        #expect(event.updated == [id])
        #expect(event.deleted.isEmpty)
        #expect(event.invalidated.isEmpty)
        #expect(LibrarySaveEvent(Notification(name: ModelContext.didSave)) == nil)
    }
}
