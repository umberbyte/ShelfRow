//
//  PreferencesView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import UniformTypeIdentifiers

enum MaintenanceAction: String {
    case manageVolumes
    case importXMLLibrary
    case migrateLegacyThumbnails
    case repairThumbnails
    case repairEmptyTitles
}

extension Notification.Name {
    static let maintenanceActionRequested = Notification.Name("ShelfRowMaintenanceActionRequested")
    static let keywordEquivalenceEditRequested = Notification.Name("ShelfRowKeywordEquivalenceEditRequested")
}

enum KeywordEquivalenceEditRequest {
    static let fieldKey = "pendingKeywordEquivalenceField"
    static let termKey = "pendingKeywordEquivalenceTerm"

    static func store(field: KeywordEquivalenceField, term: String) {
        UserDefaults.standard.set(field.rawValue, forKey: fieldKey)
        UserDefaults.standard.set(term, forKey: termKey)
    }

    static func consume() -> (field: KeywordEquivalenceField, term: String)? {
        let defaults = UserDefaults.standard
        guard let rawField = defaults.string(forKey: fieldKey),
              let field = KeywordEquivalenceField(rawValue: rawField),
              let term = defaults.string(forKey: termKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else {
            return nil
        }
        defaults.removeObject(forKey: fieldKey)
        defaults.removeObject(forKey: termKey)
        return (field, term)
    }

    static var hasPendingRequest: Bool {
        UserDefaults.standard.string(forKey: fieldKey) != nil
    }
}

enum PreferencesLayout {
    static let windowWidth: CGFloat = 860
    static let windowHeight: CGFloat = 600
    static let labelWidth: CGFloat = 190
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 13)
    static let smallCaptionFont = Font.system(size: 12)
    static let sectionTitleFont = Font.system(size: 15, weight: .semibold)
}

private enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case viewer
    case helper
    case keywords
    case customize
    case security
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .viewer: return "ビューア"
        case .helper: return "ヘルパー"
        case .keywords: return "キーワード"
        case .customize: return "カスタマイズ"
        case .security: return "セキュリティ"
        case .maintenance: return "保守"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .viewer: return "play.rectangle"
        case .helper: return "square.and.arrow.up"
        case .keywords: return "tag"
        case .customize: return "slider.horizontal.3"
        case .security: return "lock"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

struct PreferencesView: View {
    @State private var selectedPane: PreferencesPane? = .general

    var body: some View {
        NavigationSplitView {
            List(PreferencesPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .font(PreferencesLayout.bodyFont)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationTitle("設定")
            .frame(minWidth: 180, idealWidth: 190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    preferencesDetail(for: selectedPane ?? .general)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle((selectedPane ?? .general).title)
        }
        .frame(width: PreferencesLayout.windowWidth, height: PreferencesLayout.windowHeight)
        .onAppear {
            if KeywordEquivalenceEditRequest.hasPendingRequest {
                selectedPane = .keywords
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keywordEquivalenceEditRequested)) { _ in
            selectedPane = .keywords
        }
    }

    @ViewBuilder
    private func preferencesDetail(for pane: PreferencesPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsView()
        case .viewer:
            SlideshowSettingsView()
        case .helper:
            HelperSettingsView()
        case .keywords:
            KeywordEquivalenceSettingsView()
        case .customize:
            CustomizeSettingsView()
        case .security:
            SecuritySettingsView()
        case .maintenance:
            MaintenanceSettingsView()
        }
    }
}
