//
//  ShelfRowApp.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData

/// Implements the 環境設定 > 詳細設定 "メインウインドウを閉じると終了" behavior.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Default is ON (classic Stackroom behavior)
        if UserDefaults.standard.object(forKey: "advancedCloseOnExit") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "advancedCloseOnExit")
    }
}

@main
struct ShelfRowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Volume.self,
            Item.self,
            Shelf.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        
        #if os(macOS)
        Settings {
            PreferencesView()
        }
        .modelContainer(sharedModelContainer)
        #endif
    }
}
