//
//  ShelfRowApp.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "システム"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 3-generation startup backup (runs before ModelContainer opens the DB)

/// Copies the SwiftData store files to a rotating 3-generation backup inside
/// Application Support/StartupBackups/ each time the app starts.
/// Purpose: recovery from logical database corruption.
/// gen0 = newest, gen2 = oldest. Errors are silently ignored so startup is never blocked.
private enum SwiftDataStartupBackup {
    private static let maxGenerations = 3
    private static let storeFileNames = ["default.store", "default.store-wal", "default.store-shm"]
    private static let backupDirName = "StartupBackups"

    static func perform() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let storeDir = appSupport
        guard fm.fileExists(atPath: storeDir.appendingPathComponent("default.store").path) else { return }

        let backupRoot = appSupport.appendingPathComponent(backupDirName, isDirectory: true)

        // Rotate: delete oldest generation, then shift gen(n) → gen(n+1)
        let oldestDir = backupRoot.appendingPathComponent("gen\(maxGenerations - 1)")
        try? fm.removeItem(at: oldestDir)
        for gen in stride(from: maxGenerations - 2, through: 0, by: -1) {
            let src = backupRoot.appendingPathComponent("gen\(gen)")
            let dst = backupRoot.appendingPathComponent("gen\(gen + 1)")
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Copy current store files into gen0
        let gen0 = backupRoot.appendingPathComponent("gen0")
        do {
            try fm.createDirectory(at: gen0, withIntermediateDirectories: true)
            for name in storeFileNames {
                let src = storeDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.copyItem(at: src, to: gen0.appendingPathComponent(name))
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            try stamp.write(to: gen0.appendingPathComponent("backup_date.txt"), atomically: true, encoding: .utf8)
        } catch {
            // Never block startup due to backup failure
        }
    }
}

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
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var sharedModelContainer: ModelContainer = {
        SwiftDataStartupBackup.perform()

        let schema = Schema([
            Volume.self,
            Item.self,
            Shelf.self,
            CoverExtractionRecord.self,
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
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 990, height: 620)
        .windowResizability(.contentMinSize)
        
        #if os(macOS)
        Settings {
            PreferencesView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .modelContainer(sharedModelContainer)
        #endif
    }
}
