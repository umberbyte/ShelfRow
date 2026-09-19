//
//  ShelfRowApp.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData
import OSLog

private let windowLifecycleLogger = Logger(subsystem: "jp.aromatics.ShelfRow", category: "WindowLifecycle")

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
    private var windowCloseObserver: NSObjectProtocol?
    private var isHandlingWindowClose = false

    /// AppKit's own identifier for the window a SwiftUI `Settings` scene creates.
    /// Undocumented but stable since it first shipped, and the only way to pick
    /// 環境設定 out of `NSApp.windows` without giving it a window of our own.
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_settings_window"
    /// Fallback in case that identifier ever changes: the window titles macOS
    /// gives a Settings scene by default.
    private static let settingsWindowTitles: Set<String> = ["環境設定", "Settings", "Preferences"]

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == settingsWindowIdentifier || settingsWindowTitles.contains(window.title)
    }

    private static func describe(_ window: NSWindow) -> String {
        "title=\"\(window.title)\" identifier=\(window.identifier?.rawValue ?? "nil") " +
        "class=\(type(of: window)) visible=\(window.isVisible) isSettings=\(isSettingsWindow(window))"
    }

    static var shouldTerminateWhenMainWindowCloses: Bool {
        // Default is ON (classic Stackroom behavior)
        if UserDefaults.standard.object(forKey: "advancedCloseOnExit") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "advancedCloseOnExit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.shouldTerminateWhenMainWindowCloses
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowLifecycleLogger.info("applicationDidFinishLaunching: registering window close observer")

        // AppKit only calls applicationShouldTerminateAfterLastWindowClosed once
        // every window is gone, which never happens while 環境設定 stays open — the
        // main window closing then leaves 環境設定 stranded instead of quitting.
        // Watched by hand instead: any window closing is a chance to check whether
        // only 環境設定 is left, which counts the same as the main window being the
        // last one.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let closedWindow = notification.object as? NSWindow else {
                windowLifecycleLogger.error("willCloseNotification fired with a non-NSWindow object")
                return
            }
            self?.windowDidClose(closedWindow)
        }
    }

    private func windowDidClose(_ closedWindow: NSWindow) {
        windowLifecycleLogger.info("window closing: \(Self.describe(closedWindow), privacy: .public)")

        guard Self.shouldTerminateWhenMainWindowCloses else {
            windowLifecycleLogger.info("advancedCloseOnExit is off — leaving other windows as they are")
            return
        }
        guard !isHandlingWindowClose else {
            windowLifecycleLogger.info("already handling a window close — ignoring")
            return
        }
        // 環境設定 closing on its own is not "the main window closed".
        guard !Self.isSettingsWindow(closedWindow) else {
            windowLifecycleLogger.info("the closed window is 環境設定 itself — nothing to do")
            return
        }

        // Give AppKit a run-loop turn to finish tearing this window down before
        // acting: closing other windows or calling terminate(_:) synchronously from
        // inside a window's own will-close notification is unreliable — AppKit can
        // end up ignoring it mid-teardown.
        DispatchQueue.main.async { [weak self] in
            self?.terminateIfOnlySettingsWindowRemains(after: closedWindow)
        }
    }

    private func terminateIfOnlySettingsWindowRemains(after closedWindow: NSWindow) {
        guard !isHandlingWindowClose else {
            windowLifecycleLogger.info("already handling a window close — skipping the deferred check")
            return
        }

        let allWindows = NSApp.windows
        windowLifecycleLogger.info("checking \(allWindows.count, privacy: .public) window(s) after close:")
        for window in allWindows {
            windowLifecycleLogger.info("  - \(Self.describe(window), privacy: .public)")
        }

        let remaining = allWindows.filter { window in
            window !== closedWindow && window.isVisible && !Self.isSettingsWindow(window)
        }
        guard remaining.isEmpty else {
            windowLifecycleLogger.info("\(remaining.count, privacy: .public) non-Settings window(s) still open — not quitting")
            return
        }

        windowLifecycleLogger.info("only 環境設定 remains — closing it and terminating")
        isHandlingWindowClose = true
        for window in allWindows where Self.isSettingsWindow(window) {
            window.close()
        }
        NSApp.terminate(nil)
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
