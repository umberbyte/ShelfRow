//
//  ShelfRowApp.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData
import OSLog

private let windowLifecycleLogger = Logger(subsystem: ThumbnailCache.appIdentifier, category: "WindowLifecycle")

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

/// Implements the 環境設定 > 詳細設定 "メインウインドウを閉じると終了" behavior.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?
    private var isHandlingWindowClose = false

    /// AppKit's own identifier for the window a SwiftUI `Settings` scene creates.
    /// Undocumented but stable since it first shipped, and the only way to pick
    /// 環境設定 out of `NSApp.windows` without giving it a window of our own.
    /// Confirmed via logging on this app's build: "com_apple_SwiftUI_Settings_window"
    /// (capital S in "Settings").
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"
    /// Fallback in case that identifier ever changes: 環境設定 titles its window
    /// after the first settings tab (「一般」on this app's build), which is not a
    /// stable string to match on, so this checks case-insensitively instead of
    /// listing every possible tab name.
    private static let settingsWindowTitleHints: Set<String> = ["設定", "環境設定", "settings", "preferences"]

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == settingsWindowIdentifier {
            return true
        }
        // 環境設定's window titles itself after the selected tab (confirmed via
        // logging: "一般" for the General tab), not a fixed "Settings" string, so
        // this is a weak fallback only — matched case-insensitively in case a future
        // build's identifier differs, never expected to fire on this one.
        return settingsWindowTitleHints.contains(window.title.lowercased())
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
        windowLifecycleLogger.debug("window closing: \(Self.describe(closedWindow), privacy: .public)")

        guard Self.shouldTerminateWhenMainWindowCloses, !isHandlingWindowClose,
              !Self.isSettingsWindow(closedWindow) else {
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
        guard !isHandlingWindowClose else { return }

        let allWindows = NSApp.windows
        let remaining = allWindows.filter { window in
            window !== closedWindow && window.isVisible && !Self.isSettingsWindow(window)
        }
        guard remaining.isEmpty else {
            windowLifecycleLogger.debug("\(remaining.count, privacy: .public) non-Settings window(s) still open — not quitting")
            return
        }

        windowLifecycleLogger.info("main window closed with only 環境設定 remaining — closing it and terminating")
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

    @State private var libraryStore = LibraryStore()
    @State private var cloudAccount = CloudAccountMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Reopening the store in a different mode replaces every context
                // the tree is holding, so the tree is rebuilt with it.
                .id(libraryStore.generation)
                .preferredColorScheme(appearanceMode.colorScheme)
                .environment(libraryStore)
                .environment(cloudAccount)
                .task { watchAccount() }
        }
        .modelContainer(libraryStore.container)
        .defaultSize(width: 990, height: 620)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        Settings {
            PreferencesView()
                .preferredColorScheme(appearanceMode.colorScheme)
                .environment(libraryStore)
                .environment(cloudAccount)
        }
        .modelContainer(libraryStore.container)
        #endif
    }

    private func watchAccount() {
        cloudAccount.onAvailabilityChange = { available in
            libraryStore.reconcile(accountAvailable: available)
        }
        cloudAccount.start()
    }
}
