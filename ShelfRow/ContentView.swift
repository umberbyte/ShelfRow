//
//  ContentView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

enum SidebarSelection: Hashable {
    case allBooks
    case unreadBooks
    case shelf(UUID)
}

/// Inspector text fields that can receive stamps (スタンプ) input.
enum InspectorField: Hashable {
    case title, author, keywordA, keywordB, memo, genre, relation
}

private struct ThumbnailRepairScanResult: Sendable {
    var itemIDs: [UUID]
    var monochromeCount: Int
    var landscapeCount: Int
    var missingCount: Int

    nonisolated init(itemIDs: [UUID] = [], monochromeCount: Int = 0, landscapeCount: Int = 0, missingCount: Int = 0) {
        self.itemIDs = itemIDs
        self.monochromeCount = monochromeCount
        self.landscapeCount = landscapeCount
        self.missingCount = missingCount
    }

    nonisolated func merged(with other: ThumbnailRepairScanResult) -> ThumbnailRepairScanResult {
        ThumbnailRepairScanResult(
            itemIDs: itemIDs + other.itemIDs,
            monochromeCount: monochromeCount + other.monochromeCount,
            landscapeCount: landscapeCount + other.landscapeCount,
            missingCount: missingCount + other.missingCount
        )
    }
}

private struct SmartShelfEditorPresentation: Identifiable {
    let id: String
    let shelf: Shelf?

    init(shelf: Shelf?) {
        self.shelf = shelf
        self.id = shelf.map { "edit-\($0.id.uuidString)" } ?? "new"
    }
}

private enum DroppedFileKind: Equatable {
    case folder
    case pageCountedArchive
    case helperFile

    var shouldUsePageCountForBookType: Bool {
        switch self {
        case .folder, .pageCountedArchive: return true
        case .helperFile: return false
        }
    }

    var fileType: Int {
        switch self {
        case .folder: return 1
        case .pageCountedArchive: return 2
        case .helperFile: return 0
        }
    }
}

private struct DroppedFilePageCountUpdate: Sendable {
    let itemID: UUID
    let pageCount: Int
    let shouldApplyAutoBookType: Bool
}

private struct ShelfDropDelegate: DropDelegate {
    let targetShelfID: UUID
    let targetType: Int
    let draggingShelfID: Binding<UUID?>
    let moveAction: (UUID, UUID, Int) -> Void
    let commitAction: (Int) -> Void
    let fileDropAction: ([NSItemProvider], UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard !hasFileURLs(info) else { return }
        guard let sourceID = draggingShelfID.wrappedValue,
              sourceID != targetShelfID else {
            return
        }
        moveAction(sourceID, targetShelfID, targetType)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: hasFileURLs(info) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if hasFileURLs(info) {
            guard targetType == 0 else { return false }
            fileDropAction(info.itemProviders(for: [.fileURL]), targetShelfID)
            draggingShelfID.wrappedValue = nil
            return true
        }

        commitAction(targetType)
        draggingShelfID.wrappedValue = nil
        return true
    }

    private func hasFileURLs(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }
}

/// Sort keys for the main content view (右クリック > 並び替え, list headers).
enum ItemSortKey: String, CaseIterable, Identifiable {
    case unread, bookType, title, rating, author, genre, relation, keywordA, keywordB, addedDate, lastReadDate, pages

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread:       return "未読"
        case .bookType:     return "種類"
        case .title:        return "タイトル"
        case .rating:       return "レート"
        case .author:       return "作者"
        case .genre:        return "ジャンル"
        case .relation:     return "関連"
        case .keywordA:     return "キーワードA"
        case .keywordB:     return "キーワードB"
        case .addedDate:    return "登録日"
        case .lastReadDate: return "読んだ日"
        case .pages:        return "ページ数"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    // DB Queries
    @Query(sort: \Item.title) private var allItems: [Item]
    @Query(sort: \Shelf.title) private var shelves: [Shelf]

    // AppStorage Settings (Customizable metadata labels; empty = classic default)
    @AppStorage("typeNameThickBook") private var thickBook = ""
    @AppStorage("typeNameThinBook") private var thinBook = ""
    @AppStorage("typeNamePartBook") private var partBook = ""
    @AppStorage("typeNameImageSet") private var imageSet = ""
    @AppStorage("typeNameText") private var textType = ""
    @AppStorage("typeNameMovie") private var movieType = ""

    @AppStorage("fieldNameAuthor") private var fieldAuthor = ""
    @AppStorage("fieldNameGenre") private var fieldGenre = ""
    @AppStorage("fieldNameRelation") private var fieldRelation = ""
    @AppStorage("fieldNameKeywordA") private var fieldKeywordA = ""
    @AppStorage("fieldNameKeywordB") private var fieldKeywordB = ""
    @AppStorage("customRenameFormat") private var customRenameFormat = "[@author] @title"
    @AppStorage("keywordEquivalenceRulesJson") private var keywordEquivalenceRulesJson = "[]"

    @AppStorage("advancedPasswordLockEnabled") private var lockEnabled = false
    @AppStorage("advancedPasswordValue") private var passwordValue = ""

    // Viewer helper settings (環境設定 > スライドショー / ヘルパー)
    @AppStorage("slideshowHelperPath") private var slideshowHelperName = ""
    @AppStorage("slideshowHelperFullPath") private var slideshowHelperFullPath = ""
    @AppStorage("zipHelperPath") private var zipHelperName = ""
    @AppStorage("zipHelperFullPath") private var zipHelperFullPath = ""
    @AppStorage("helperExtensionsList") private var helperExtensionsList = "mov, avi, mpg\nrar, zip, 7z"
    @AppStorage("helperApplicationsList") private var helperApplicationsList = "\n"

    // UI Selection and view states
    @State private var sidebarSelection: SidebarSelection? = .allBooks
    @State private var selectedItemID: UUID? = nil
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var selectionAnchorItemID: UUID? = nil
    @State private var selectedDisplayIndex: Int? = nil
    @State private var coverPrefetchTask: Task<Void, Never>? = nil
    @State private var lastKeyboardScrollIndex: Int? = nil
    @State private var scrollPositionItemID: UUID? = nil
    @AppStorage("mainViewIsGrid") private var isGridView = false

    // Live Filters (classic toolbar segments)
    @State private var searchText = ""
    @State private var unreadFilterSelection = 0 // 0 = ALL, 1 = Unread Only (O)
    @State private var ratingFilterSelection: Set<Int> = [] // empty = ALL
    @State private var typeFilterSelection: Set<Int> = []   // empty = ALL

    // Sort order (右クリック > 並び替え)
    @AppStorage("mainSortKey") private var sortKey: ItemSortKey = .title
    @AppStorage("mainSortAscending") private var sortAscending = true

    // Visible list columns (ヘッダー右クリックで切替、title列は常に表示)
    @AppStorage("listVisibleColumns") private var listVisibleColumnsRaw = "unread,bookType,rating,author,genre,addedDate"

    // Cached filtered/sorted items (recomputed only when displayToken changes)
    @State private var displayItems: [Item] = []

    // Security simple lock state
    @State private var isLocked = false
    @State private var passwordInput = ""
    @State private var showLockError = false

    // Import progress state
    @State private var isImporting = false
    @State private var totalBooks = 0
    @State private var processedBooks = 0
    @State private var totalPlaylists = 0
    @State private var processedPlaylists = 0
    @State private var importMessage = ""
    @State private var showImportResult = false

    // Sheet triggers
    @State private var showVolumeManager = false
    @State private var smartShelfEditorPresentation: SmartShelfEditorPresentation? = nil
    @State private var showCoverEditor = false
    @State private var showMissingFileAlert = false
    @State private var missingFileDetail = ""
    @State private var openErrorMessage: String? = nil

    // Drag & drop batch registration state
    @State private var dropQueueRemaining = 0
    @State private var draggingShelfID: UUID? = nil
    @State private var staticShelfOrderIDs: [UUID] = []
    @State private var smartShelfOrderIDs: [UUID] = []
    @State private var editingShelfID: UUID? = nil
    @State private var editingShelfTitle = ""
    @State private var pendingSidebarScrollShelfID: UUID? = nil

    @FocusState private var mainContentHasFocus: Bool
    @FocusState private var focusedShelfTitleID: UUID?

    private var selectedItem: Item? {
        guard let selectedID = selectedItemID else { return nil }
        if let index = selectedDisplayIndex,
           displayItems.indices.contains(index),
           displayItems[index].id == selectedID {
            return displayItems[index]
        }
        if let visible = displayItems.first(where: { $0.id == selectedID }) {
            return visible
        }
        return allItems.first(where: { $0.id == selectedID })
    }

    private var typeNames: [String] {
        [customName(thickBook, default: "厚い本"),
         customName(thinBook, default: "薄い本"),
         customName(partBook, default: "本の一部"),
         customName(imageSet, default: "画像セット"),
         customName(textType, default: "テキスト"),
         customName(movieType, default: "ムービー")]
    }

    private var currentCollectionTitle: String {
        switch sidebarSelection {
        case .allBooks:
            return "すべての項目"
        case .unreadBooks:
            return "未読"
        case .shelf(let shelfID):
            return shelves.first(where: { $0.id == shelfID })?.title ?? "シェルフ"
        case .none:
            return "すべての項目"
        }
    }

    private var isDarkAppearance: Bool {
        colorScheme == .dark
    }

    private var modernSurfaceColor: Color {
        isDarkAppearance
            ? Color(red: 0.055, green: 0.065, blue: 0.075)
            : Color(NSColor.windowBackgroundColor)
    }

    private var modernPanelColor: Color {
        isDarkAppearance
            ? Color(red: 0.105, green: 0.120, blue: 0.140)
            : Color(NSColor.controlBackgroundColor)
    }

    private var primaryTextColor: Color {
        Color(NSColor.labelColor)
    }

    private var secondaryTextColor: Color {
        Color(NSColor.secondaryLabelColor)
    }

    private var tertiaryTextColor: Color {
        Color(NSColor.tertiaryLabelColor)
    }

    private var inspectorTextColor: Color {
        isDarkAppearance ? primaryTextColor : .black
    }

    private var controlFillColor: Color {
        isDarkAppearance ? Color.white.opacity(0.075) : Color.black.opacity(0.055)
    }

    private var subtleFillColor: Color {
        isDarkAppearance ? Color.white.opacity(0.035) : Color.black.opacity(0.035)
    }

    private var alternateRowFillColor: Color {
        isDarkAppearance ? Color.white.opacity(0.035) : Color.black.opacity(0.035)
    }

    private var rowFillColor: Color {
        isDarkAppearance ? Color.white.opacity(0.015) : Color.black.opacity(0.012)
    }

    private var separatorTintColor: Color {
        isDarkAppearance ? Color.white.opacity(0.10) : Color.black.opacity(0.12)
    }

    private var sidebarGradientColors: [Color] {
        if isDarkAppearance {
            return [
                Color(red: 0.155, green: 0.165, blue: 0.190),
                Color(red: 0.105, green: 0.115, blue: 0.140)
            ]
        }
        return [
            Color(NSColor.controlBackgroundColor),
            Color(NSColor.windowBackgroundColor)
        ]
    }

    var body: some View {
        ZStack {
            if isLocked {
                // Classic Password Lock Screen
                passwordLockScreen
            } else {
                // Main Application Window (Modern 3-Pane Structure)
                VStack(spacing: 0) {
                    // Three-pane split view. The side panes keep their
                    // user-adjusted widths; window resizing is absorbed by the
                    // flexible list/grid pane in the middle.
                    HSplitView {
                        sidebarPane
                            .frame(minWidth: 240, idealWidth: 260, maxWidth: 360)
                            .background(SplitViewAutosave(name: "ShelfRow.MainSplitView"))

                        mainContentPane
                            .frame(minWidth: 620, maxWidth: .infinity)

                        detailPane
                            .frame(minWidth: 300, idealWidth: 320, maxWidth: 440)
                    }
                }
                .background(modernSurfaceColor)
            }
        }
        .frame(minWidth: 1160, minHeight: 680)
        .sheet(isPresented: $showVolumeManager) {
            VolumeRelocationView(isPresented: $showVolumeManager)
        }
        .sheet(isPresented: $showImportResult) {
            importResultView
        }
        .sheet(item: $smartShelfEditorPresentation) { presentation in
            SmartShelfEditorView(
                isPresented: Binding(
                    get: { smartShelfEditorPresentation != nil },
                    set: { if !$0 { smartShelfEditorPresentation = nil } }
                ),
                editingShelf: presentation.shelf
            )
        }
        .sheet(isPresented: $showCoverEditor) {
            if let item = selectedItem {
                CoverEditorView(item: item, isPresented: $showCoverEditor)
            }
        }
        .alert("開けませんでした", isPresented: Binding(
            get: { openErrorMessage != nil },
            set: { if !$0 { openErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openErrorMessage ?? "")
        }
        // Attached to a separate background host so it coexists with the
        // "開けませんでした" alert above (SwiftUI honors only one .alert per view).
        .background(
            Color.clear
                .alert("ファイルにアクセスできません", isPresented: $showMissingFileAlert) {
                    Button("ボリューム管理を開く") {
                        showVolumeManager = true
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("書籍ファイルが移動・削除されているか、アクセス権がありません。「ボリューム管理」で親ボリュームのフォルダを再割り当てすると、アクセス権が保存されます。\n\n" + missingFileDetail)
                }
        )
        .overlay {
            if isImporting {
                importProgressOverlay
            }
        }
        .onAppear {
            // Apply security lock if enabled
            if lockEnabled && !passwordValue.isEmpty {
                isLocked = true
            }
            syncShelfOrderStateFromModel()
        }
        .onChange(of: shelfOrderSourceToken) { _, _ in
            guard draggingShelfID == nil else { return }
            syncShelfOrderStateFromModel()
        }
        // Supporting Drag & Drop to Import Files seamlessly in initial or running states
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers, targetShelfID: currentStaticShelfID())
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .maintenanceActionRequested)) { notification in
            guard let action = notification.object as? MaintenanceAction else { return }
            runMaintenanceAction(action)
        }
    }

    // MARK: - Password Lock Screen
    private var passwordLockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("ShelfRowはロックされています。")
                .font(.headline)

            TextField("パスワードを入力してください", text: $passwordInput, onCommit: unlockLibrary)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .multilineTextAlignment(.center)

            if showLockError {
                Text("パスワードが正しくありません。")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button("OK") {
                unlockLibrary()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func unlockLibrary() {
        if passwordInput == passwordValue {
            isLocked = false
            showLockError = false
            passwordInput = ""
        } else {
            showLockError = true
            passwordInput = ""
        }
    }

    // MARK: - Modern Main Header
    private var modernMainHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentCollectionTitle)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(primaryTextColor)
                    Text("\(displayItems.count.formatted()) 項目")
                        .font(.system(size: 13))
                        .foregroundStyle(secondaryTextColor)
                }

                Spacer(minLength: 16)

                viewModeSwitcher

                Menu {
                    sortMenuItems
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: sortAscending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                        Text("並び替え")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isGridView ? secondaryTextColor : tertiaryTextColor)
                    }
                    .foregroundStyle(isGridView ? primaryTextColor : tertiaryTextColor)
                }
                .menuStyle(.borderlessButton)
                .disabled(!isGridView)
                .frame(width: 116, height: 36, alignment: .center)
                .background(headerControlBackground)
                .contentShape(Rectangle())

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(secondaryTextColor)
                    TextField("検索", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(primaryTextColor)
                }
                .padding(.horizontal, 12)
                .frame(width: 300, height: 36)
                .background(headerControlBackground)
            }

            classicFilterSegments
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [
                    isDarkAppearance ? Color.white.opacity(0.045) : Color.black.opacity(0.025),
                    isDarkAppearance ? Color.white.opacity(0.015) : Color.black.opacity(0.006)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var headerControlBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(controlFillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(separatorTintColor, lineWidth: 1)
            )
    }

    private var viewModeSwitcher: some View {
        HStack(spacing: 4) {
            viewModeButton(title: "リスト", icon: "list.bullet", isSelected: !isGridView) {
                isGridView = false
            }
            viewModeButton(title: "グリッド", icon: "square.grid.2x2", isSelected: isGridView) {
                isGridView = true
            }
        }
        .padding(4)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(controlFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(separatorTintColor, lineWidth: 1)
                )
        )
    }

    private func viewModeButton(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : primaryTextColor)
            .frame(width: 86, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Modern Filter Segments (未読 / レート / 種類, multi-selectable)
    private var classicFilterSegments: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                filterSegment(isSelected: unreadFilterSelection == 1, minWidth: 86) {
                    unreadFilterSelection = unreadFilterSelection == 1 ? 0 : 1
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 14, height: 14)
                            .shadow(color: .green.opacity(0.55), radius: 5)
                            .accessibilityHidden(true)
                        Text("未読")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }

                verticalFilterSeparator

                Text("種別")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryTextColor)

                filterTypeButton(index: nil, title: "すべて", isSelected: typeFilterSelection.isEmpty) {
                    typeFilterSelection.removeAll()
                }

                ForEach(0..<BookTypeInfo.count, id: \.self) { idx in
                    filterTypeButton(index: idx, title: typeNames[idx], isSelected: typeFilterSelection.contains(idx)) {
                        if typeFilterSelection.contains(idx) {
                            typeFilterSelection.remove(idx)
                        } else {
                            typeFilterSelection.insert(idx)
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                verticalFilterSeparator

                Text("評価")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryTextColor)

                ForEach(1...5, id: \.self) { rate in
                    filterSegment(isSelected: ratingFilterSelection.contains(rate), minWidth: 72) {
                        if ratingFilterSelection.contains(rate) {
                            ratingFilterSelection.remove(rate)
                        } else {
                            ratingFilterSelection.insert(rate)
                        }
                    } label: {
                        starRow(count: rate, filled: ratingFilterSelection.contains(rate))
                    }
                }

                Spacer()

                Button("フィルタをクリア") {
                    unreadFilterSelection = 0
                    typeFilterSelection.removeAll()
                    ratingFilterSelection.removeAll()
                    searchText = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryTextColor)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(headerControlBackground)
            }
        }
    }

    private var verticalFilterSeparator: some View {
        Rectangle()
            .fill(separatorTintColor)
            .frame(width: 1, height: 20)
    }

    private func filterTypeButton(index: Int?, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        filterSegment(isSelected: isSelected, minWidth: 78, action: action) {
            HStack(spacing: 7) {
                if let index {
                    Image(systemName: BookTypeInfo.systemImage(for: index))
                        .font(.system(size: 15))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(BookTypeInfo.color(for: index))
                } else {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.yellow)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .help(title)
    }

    /// A compact star-with-number label used by the rating filter (★1 … ★5).
    private func starRow(count: Int, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(filled ? .white : Color.yellow)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(filled ? .white : primaryTextColor)
        }
    }

    private func filterSegment<Label: View>(isSelected: Bool, minWidth: CGFloat = 32, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minWidth: minWidth, minHeight: 36)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : controlFillColor)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.white.opacity(0.22) : separatorTintColor, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? .white : primaryTextColor)
        }
        .buttonStyle(.plain)
    }

    private func orderedShelves(type: Int) -> [Shelf] {
        let modelOrder = shelves
            .filter { $0.type == type }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        let orderIDs = shelfOrderIDs(type: type)
        guard !orderIDs.isEmpty else { return modelOrder }

        let modelIDs = Set(modelOrder.map(\.id))
        let orderIDSet = Set(orderIDs)
        guard modelIDs == orderIDSet else { return modelOrder }

        let byID = Dictionary(uniqueKeysWithValues: modelOrder.map { ($0.id, $0) })
        return orderIDs.compactMap { byID[$0] }
    }

    private func shelfOrderIDs(type: Int) -> [UUID] {
        type == 0 ? staticShelfOrderIDs : smartShelfOrderIDs
    }

    private var shelfOrderSourceToken: String {
        shelves
            .sorted { lhs, rhs in
                if lhs.type != rhs.type {
                    return lhs.type < rhs.type
                }
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map { "\($0.type):\($0.id.uuidString):\($0.sortOrder):\($0.title)" }
            .joined(separator: "|")
    }

    private func syncShelfOrderStateFromModel() {
        staticShelfOrderIDs = shelves
            .filter { $0.type == 0 }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map(\.id)

        smartShelfOrderIDs = shelves
            .filter { $0.type == 1 }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map(\.id)
    }

    // MARK: - Sidebar Pane
    private var sidebarPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    Text("ShelfRow")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(primaryTextColor)
                }
                .padding(.top, 18)
                .padding(.horizontal, 20)
            }

            ScrollViewReader { sidebarProxy in
                List {
                    Section {
                        sidebarSelectionButton(.allBooks) {
                            sidebarLibraryLabel("すべての項目", systemImage: "doc.text", count: allItems.count)
                        }
                        sidebarSelectionButton(.unreadBooks) {
                            sidebarLibraryLabel("未読", systemImage: "circle.fill", count: allItems.filter(\.isUnread).count)
                        }
                    } header: {
                        sidebarSectionHeader("ライブラリ")
                    }

                    Section {
                        let staticShelves = orderedShelves(type: 0)
                        ForEach(staticShelves) { shelf in
                            sidebarSelectionButton(.shelf(shelf.id)) {
                                shelfLabel(shelf)
                            }
                            .id(shelf.id)
                            .onDrag {
                                draggingShelfID = shelf.id
                                return NSItemProvider(object: shelf.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text, .fileURL],
                                delegate: ShelfDropDelegate(
                                    targetShelfID: shelf.id,
                                    targetType: shelf.type,
                                    draggingShelfID: $draggingShelfID,
                                    moveAction: reorderShelfByDrag,
                                    commitAction: commitShelfDrag,
                                    fileDropAction: handleFileDrop(providers:targetShelfID:)
                                )
                            )
                            .contextMenu {
                                Button("削除") {
                                    deleteShelf(shelf)
                                }
                            }
                        }
                    } header: {
                        sidebarSectionHeader("お気に入り")
                    }

                    Section {
                        let smartShelves = orderedShelves(type: 1)
                        ForEach(smartShelves) { shelf in
                            sidebarSelectionButton(.shelf(shelf.id)) {
                                shelfLabel(shelf)
                            }
                            .id(shelf.id)
                            .onDrag {
                                draggingShelfID = shelf.id
                                return NSItemProvider(object: shelf.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text, .fileURL],
                                delegate: ShelfDropDelegate(
                                    targetShelfID: shelf.id,
                                    targetType: shelf.type,
                                    draggingShelfID: $draggingShelfID,
                                    moveAction: reorderShelfByDrag,
                                    commitAction: commitShelfDrag,
                                    fileDropAction: handleFileDrop(providers:targetShelfID:)
                                )
                            )
                            .contextMenu {
                                Button("編集...") {
                                    smartShelfEditorPresentation = SmartShelfEditorPresentation(shelf: shelf)
                                }
                                Button("削除") {
                                    deleteShelf(shelf)
                                }
                            }
                        }
                    } header: {
                        sidebarSectionHeader("スマートシェルフ")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: pendingSidebarScrollShelfID) { _, shelfID in
                    guard let shelfID else { return }
                    Task { @MainActor in
                        for attempt in 0..<3 {
                            await Task.yield()
                            if attempt > 0 {
                                try? await Task.sleep(for: .milliseconds(80))
                            }
                            withAnimation(.easeOut(duration: 0.18)) {
                                sidebarProxy.scrollTo(shelfID, anchor: .center)
                            }
                        }
                        focusedShelfTitleID = shelfID
                        pendingSidebarScrollShelfID = nil
                    }
                }
            }

            Divider()

            // Bottom footer controls: shelf menu and Settings button.
            HStack(spacing: 8) {
                // Add button (+)
                Menu {
                    Button("新規スマートシェルフ...") {
                        smartShelfEditorPresentation = SmartShelfEditorPresentation(shelf: nil)
                    }
                    Button("新規標準シェルフ...") {
                        createStaticShelf()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(primaryTextColor)
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("シェルフを追加")
                .buttonStyle(.plain)
                .fixedSize()
                .background(modernIconButtonBackground)

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primaryTextColor)
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("環境設定")
                .buttonStyle(.plain)
                .background(modernIconButtonBackground)
                .help("環境設定")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(subtleFillColor)
        }
        .background(
            LinearGradient(
                colors: sidebarGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var modernIconButtonBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(controlFillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(separatorTintColor, lineWidth: 1)
            )
    }

    private func sidebarSelectionButton<Label: View>(_ selection: SidebarSelection, @ViewBuilder label: () -> Label) -> some View {
        Button {
            sidebarSelection = selection
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 32, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(sidebarSelection == selection ? Color.accentColor.opacity(0.95) : Color.clear)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        )
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isDarkAppearance ? Color.white.opacity(0.74) : .black)
    }

    private func sidebarLibraryLabel(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(systemImage == "circle.fill" ? .green : secondaryTextColor)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(primaryTextColor)
            Spacer()
            countBadge(count)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func countBadge(_ count: Int) -> some View {
        Text(count.formatted())
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(isDarkAppearance ? Color.white.opacity(0.14) : Color.black.opacity(0.28)))
    }

    private func shelfItemCount(_ shelf: Shelf) -> Int {
        if shelf.type == 1 {
            let conditions = SmartConditionsCodec.decode(shelf.smartConditionsJson)
            let now = Date()
            return allItems.filter { SmartConditionsCodec.matches($0, conditions: conditions, now: now) }.count
        }
        return shelf.items?.count ?? 0
    }

    private func shelfLabel(_ shelf: Shelf) -> some View {
        HStack(spacing: 10) {
            Image(systemName: shelf.type == 1 ? "gearshape" : BookTypeInfo.systemImage(for: shelf.icon))
                .foregroundStyle(shelf.type == 1 ? .purple : BookTypeInfo.folderColor(forIcon: shelf.icon))
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22)
            if editingShelfID == shelf.id {
                TextField("シェルフ名", text: $editingShelfTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryTextColor)
                    .accessibilityLabel("シェルフ名")
                    .focused($focusedShelfTitleID, equals: shelf.id)
                    .onSubmit {
                        commitEditingShelfTitle(shelf)
                    }
                    .onAppear {
                        focusedShelfTitleID = shelf.id
                    }
            } else {
                Text(shelf.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(primaryTextColor)
            }
            Spacer()
            countBadge(shelfItemCount(shelf))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - List Columns (shared by the header and each row for alignment)
    private struct ListColumn: Identifiable {
        let key: ItemSortKey
        let title: String
        let width: CGFloat?   // nil = flexible (title column)
        let alignment: Alignment
        var id: String { key.rawValue }
    }

    /// Canonical column order; the visible subset is filtered from this.
    /// The title column is always shown and cannot be toggled off.
    private static let columnOrder: [ItemSortKey] = [
        .unread, .bookType, .title, .rating, .author, .genre,
        .relation, .keywordA, .keywordB, .lastReadDate, .addedDate
    ]

    /// Columns offered in the header right-click show/hide menu (title excluded).
    private static let toggleableColumns: [ItemSortKey] = [
        .unread, .bookType, .rating, .author, .genre,
        .relation, .keywordA, .keywordB, .lastReadDate, .addedDate
    ]

    private func columnWidth(_ key: ItemSortKey) -> CGFloat? {
        switch key {
        case .unread:       return 38
        case .bookType:     return 38
        case .title:        return nil   // flexible
        case .rating:       return 92
        case .author:       return 120
        case .genre:        return 90
        case .relation:     return 90
        case .keywordA:     return 100
        case .keywordB:     return 100
        case .lastReadDate: return 84
        case .addedDate:    return 84
        case .pages:        return 56
        }
    }

    private func columnAlignment(_ key: ItemSortKey) -> Alignment {
        switch key {
        case .unread, .bookType: return .center
        case .pages:             return .trailing
        default:                 return .leading
        }
    }

    private var visibleColumnKeys: Set<String> {
        Set(listVisibleColumnsRaw.split(separator: ",").map(String.init))
    }

    /// The currently visible columns, in canonical order (title always shown).
    private var listColumns: [ListColumn] {
        let visible = visibleColumnKeys
        return Self.columnOrder
            .filter { $0 == .title || visible.contains($0.rawValue) }
            .map { ListColumn(key: $0, title: $0.label, width: columnWidth($0), alignment: columnAlignment($0)) }
    }

    private func toggleColumn(_ key: ItemSortKey) {
        var visible = visibleColumnKeys
        if visible.contains(key.rawValue) {
            visible.remove(key.rawValue)
        } else {
            visible.insert(key.rawValue)
        }
        // Persist in canonical order for stable storage
        listVisibleColumnsRaw = Self.toggleableColumns
            .filter { visible.contains($0.rawValue) }
            .map { $0.rawValue }
            .joined(separator: ",")
    }

    // MARK: - Main Content Pane (List/Grid)
    private var mainContentPane: some View {
        VStack(spacing: 0) {
            let itemsToDisplay = displayItems

            modernMainHeader

            Divider()
                .overlay(separatorTintColor)

            if itemsToDisplay.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundStyle(tertiaryTextColor)
                    Text(allItems.isEmpty ? "ライブラリは空です。" : "該当する本がありません。")
                        .font(.headline)
                        .foregroundStyle(secondaryTextColor)
                    if allItems.isEmpty {
                        Text("ZIPや画像フォルダをここにドラッグ＆ドロップして追加できます。")
                            .font(.caption)
                            .foregroundStyle(tertiaryTextColor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(modernSurfaceColor)
            } else {
                if isGridView {
                    // Grid view: sort control bar on top
                    GeometryReader { geometry in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 16)], spacing: 16) {
                                ForEach(itemsToDisplay) { item in
                                    // Double-tap must be attached BEFORE single-tap,
                                    // otherwise the single-tap gesture swallows it.
                                    GridItemCardView(item: item, isSelected: isItemSelected(item))
                                        .contentShape(Rectangle()) // full-card hit area
                                        .id(item.id)
                                        .overlay(clickOverlay(for: item))
                                        .contextMenu {
                                            itemContextMenu(item)
                                        }
                                }
                            }
                            .padding()
                            .scrollTargetLayout()
                        }
                        .scrollPosition(id: $scrollPositionItemID)
                        .background(modernSurfaceColor)
                        .focusable()
                        .focused($mainContentHasFocus)
                        .onKeyPress(.upArrow) {
                            moveSelection(by: -gridKeyboardStep(for: geometry.size.width), extending: currentEventIsShiftModified())
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveSelection(by: gridKeyboardStep(for: geometry.size.width), extending: currentEventIsShiftModified())
                            return .handled
                        }
                        .onKeyPress(.return) {
                            if let item = selectedItem {
                                openItem(item)
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.delete) {
                            deleteSelectedItemsFromKeyboard()
                            return .handled
                        }
                        .onKeyPress(.deleteForward) {
                            deleteSelectedItemsFromKeyboard()
                            return .handled
                        }
                    }
                } else {
                    // List view: clickable column header + aligned rows
                    listHeaderRow
                    Divider()
                    // Manual selection (reliable single-click) + manual keyboard
                    // navigation. Use ScrollView/LazyVStack instead of List:
                    // SwiftUI List on macOS still fights custom single/double
                    // click gestures and made repeated key navigation sluggish
                    // with large libraries.
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(itemsToDisplay.enumerated(), id: \.element.id) { index, item in
                                classicListRow(item: item, isSelected: isItemSelected(item))
                                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(
                                                    isItemSelected(item)
                                                        ? Color.accentColor.opacity(0.92)
                                                        : (index.isMultiple(of: 2) ? alternateRowFillColor : rowFillColor)
                                            )
                                    )
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .contentShape(Rectangle()) // full-row hit area
                                    .id(item.id)
                                    .overlay(clickOverlay(for: item))
                                    .contextMenu {
                                        itemContextMenu(item)
                                    }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $scrollPositionItemID)
                    .background(modernSurfaceColor)
                    .focusable()
                    .focused($mainContentHasFocus)
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1, extending: currentEventIsShiftModified())
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1, extending: currentEventIsShiftModified())
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let item = selectedItem {
                            openItem(item)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.delete) {
                        deleteSelectedItemsFromKeyboard()
                        return .handled
                    }
                    .onKeyPress(.deleteForward) {
                        deleteSelectedItemsFromKeyboard()
                        return .handled
                    }
                }
            }
        }
        // Recompute the (cached) filtered/sorted list only when inputs change,
        // not on every selection/keystroke elsewhere.
        .onAppear {
            displayItems = computeFilteredItems()
            refreshSelectedDisplayIndex()
        }
        .onChange(of: displayToken) { _, _ in
            displayItems = computeFilteredItems()
            refreshSelectedDisplayIndex()
        }
    }

    // MARK: - Grid Sort Bar
    private var gridSortBar: some View {
        HStack {
            Spacer()
            Menu {
                sortMenuItems
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("並び替え: \(sortKey.label)")
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var sortMenuItems: some View {
        ForEach(ItemSortKey.allCases) { key in
            Button {
                applySort(key)
            } label: {
                if sortKey == key {
                    Label(key.label, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                } else {
                    Text(key.label)
                }
            }
        }
    }

    // MARK: - List Header Row (click to sort, right-click to show/hide columns)
    private var listHeaderRow: some View {
        HStack(spacing: 8) {
            ForEach(listColumns) { col in
                Button {
                    applySort(col.key)
                } label: {
                    HStack(spacing: 3) {
                        Text(col.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if sortKey == col.key {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .frame(maxWidth: col.width == nil ? .infinity : nil, alignment: col.alignment)
                    .frame(width: col.width, alignment: col.alignment)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDarkAppearance ? (sortKey == col.key ? primaryTextColor : secondaryTextColor) : .black)
                .contextMenu {
                    headerContextMenu
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(subtleFillColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(separatorTintColor)
                .frame(height: 1)
        }
        .contextMenu {
            headerContextMenu
        }
    }

    /// Header right-click menu: sort submenu + column show/hide checklist
    /// (mirrors the classic Stackroom header menu).
    @ViewBuilder
    private var headerContextMenu: some View {
        Menu("並び替え") {
            sortMenuItems
        }
        Divider()
        ForEach(Self.toggleableColumns, id: \.rawValue) { key in
            Button {
                toggleColumn(key)
            } label: {
                if visibleColumnKeys.contains(key.rawValue) {
                    Label(key.label, systemImage: "checkmark")
                } else {
                    Text(key.label)
                }
            }
        }
    }

    // MARK: - Classic List Row (columns aligned to the header)
    private func classicListRow(item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(listColumns) { col in
                listCell(col, item, isSelected: isSelected)
                    .frame(maxWidth: col.width == nil ? .infinity : nil, alignment: col.alignment)
                    .frame(width: col.width, alignment: col.alignment)
            }
        }
    }

    @ViewBuilder
    private func listCell(_ col: ListColumn, _ item: Item, isSelected: Bool) -> some View {
        // Primary/secondary text turns white on the selection highlight.
        let primaryColor: Color = isSelected ? .white : (isDarkAppearance ? primaryTextColor : .black)
        let secondaryColor: Color = isSelected ? .white.opacity(0.88) : (isDarkAppearance ? secondaryTextColor : .black)
        switch col.key {
        case .unread:
            // Green circle like classic "O"
            Circle()
                .stroke(isSelected ? Color.white : Color.green, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .opacity(item.isUnread ? 1 : 0)
        case .bookType:
            Image(systemName: BookTypeInfo.systemImage(for: item.bookType))
                .font(.system(size: 15))
                .foregroundColor(isSelected ? .white : BookTypeInfo.color(for: item.bookType))
                .help(typeNames.indices.contains(item.bookType) ? typeNames[item.bookType] : "")
        case .title:
            Text(item.title)
                .font(.system(size: 14))
                .foregroundColor(primaryColor)
                .lineLimit(1)
        case .rating:
            RatingView(rating: .constant(item.rating), interactive: false)
                .font(.system(size: 11))
        case .author:
            Text(item.author)
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .genre:
            Text(item.genre)
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .relation:
            Text(item.relation)
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .keywordA:
            Text(item.keywordA)
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .keywordB:
            Text(item.keywordB)
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .lastReadDate:
            Text(item.lastReadDate?.formatted(date: .numeric, time: .omitted) ?? "—")
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .addedDate:
            Text(item.addedDate.formatted(date: .numeric, time: .omitted))
                .font(.system(size: 13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

    // MARK: - Detail Pane (Classic Right Inspector sidepanel)
    private var detailPane: some View {
        Group {
            if let item = selectedItem {
                classicInspectorView(item: item)
            } else {
                VStack {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 28))
                        .foregroundStyle(inspectorTextColor)
                    Text("本棚から本を選択してください。")
                        .font(.caption)
                        .foregroundStyle(inspectorTextColor)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(modernPanelColor)
            }
        }
    }

    private func classicInspectorView(item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Large cover image on top
                HStack {
                    Spacer()
                    CoverImageView(item: item)
                        .frame(width: 176, height: 224)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(separatorTintColor, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(isDarkAppearance ? 0.35 : 0.16), radius: 12, x: 0, y: 6)
                    Spacer()
                }
                .padding(.top, 20)

                Text(item.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(inspectorTextColor)
                    .lineLimit(2)
                    .padding(.horizontal, 20)

                Toggle("未読にする", isOn: Binding(
                    get: { item.isUnread },
                    set: { item.isUnread = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .foregroundStyle(inspectorTextColor)
                .padding(.horizontal, 20)

                Divider().overlay(separatorTintColor).padding(.horizontal, 20)

                // Form with customized labels from Customize Settings Tab!
                VStack(spacing: 8) {
                    inspectorFieldRow(label: "タイトル:", field: .title, text: Binding(
                        get: { item.title },
                        set: { item.title = $0 }
                    ))

                    inspectorFieldRow(label: customName(fieldAuthor, default: "作者") + ":", field: .author, text: Binding(
                        get: { item.author },
                        set: { item.author = $0 }
                    ))

                    HStack {
                        Text("レート:")
                            .font(.caption)
                            .foregroundStyle(inspectorTextColor)
                            .frame(width: 78, alignment: .trailing)
                        RatingView(rating: Binding(
                            get: { item.rating },
                            set: { item.rating = $0 }
                        ))
                        Spacer()
                    }

                    inspectorFieldRow(label: customName(fieldKeywordA, default: "キーワードA") + ":", field: .keywordA, text: Binding(
                        get: { item.keywordA },
                        set: { item.keywordA = $0 }
                    ))

                    inspectorFieldRow(label: customName(fieldKeywordB, default: "キーワードB") + ":", field: .keywordB, text: Binding(
                        get: { item.keywordB },
                        set: { item.keywordB = $0 }
                    ))

                    inspectorFieldRow(label: "メモ:", field: .memo, text: Binding(
                        get: { item.memo },
                        set: { item.memo = $0 }
                    ))

                    inspectorFieldRow(label: customName(fieldGenre, default: "ジャンル") + ":", field: .genre, text: Binding(
                        get: { item.genre },
                        set: { item.genre = $0 }
                    ))

                    inspectorFieldRow(label: customName(fieldRelation, default: "関連") + ":", field: .relation, text: Binding(
                        get: { item.relation },
                        set: { item.relation = $0 }
                    ))
                }
                .padding(.horizontal, 14)

                Divider().overlay(separatorTintColor).padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("登録日: \(item.addedDate.formatted(date: .numeric, time: .omitted))")
                    if let lastRead = item.lastReadDate {
                        Text("読込日: \(lastRead.formatted(date: .numeric, time: .omitted))")
                    }
                    if item.pages > 0 {
                        Text("ページ数: \(item.pages)p")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(inspectorTextColor)
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
        .background(modernPanelColor)
    }

    private func inspectorFieldRow(label: String, field: InspectorField, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(inspectorTextColor)
                    .frame(width: 78, alignment: .trailing)

                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(inspectorTextColor)
                    .accessibilityLabel(label.replacingOccurrences(of: ":", with: ""))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(controlFillColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(separatorTintColor, lineWidth: 1)
                    )
            }

            keywordSearchButton(field: field, text: text.wrappedValue)
                .padding(.leading, 78 + 8)
        }
    }

    @ViewBuilder
    private func keywordSearchButton(field: InspectorField, text: String) -> some View {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty && field != .title {
            Menu {
                Button("キーワードを検索") {
                    searchKeyword(keyword, inLibrary: false)
                }
                Button("キーワードをライブラリで検索") {
                    searchKeyword(keyword, inLibrary: true)
                }
                if let equivalenceField = keywordEquivalenceField(for: field) {
                    Divider()
                    Button("他のキーワードと同一視...") {
                        openKeywordEquivalenceSettings(field: equivalenceField, term: keyword)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text(keyword)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("キーワードを検索")
        }
    }

    private func searchKeyword(_ keyword: String, inLibrary: Bool) {
        if inLibrary {
            sidebarSelection = .allBooks
        }
        searchText = keyword
        displayItems = computeFilteredItems()
        selectedItemID = nil
        selectedItemIDs.removeAll()
        selectionAnchorItemID = nil
        selectedDisplayIndex = nil
    }

    private func keywordEquivalenceField(for field: InspectorField) -> KeywordEquivalenceField? {
        switch field {
        case .author: return .author
        case .keywordA: return .keywordA
        case .keywordB: return .keywordB
        case .memo: return .memo
        case .genre: return .genre
        case .relation: return .relation
        case .title: return nil
        }
    }

    private func openKeywordEquivalenceSettings(field: KeywordEquivalenceField, term: String) {
        KeywordEquivalenceEditRequest.store(field: field, term: term)
        NotificationCenter.default.post(name: .keywordEquivalenceEditRequested, object: nil)
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Classic Status Bar (Bottom Bar)
    private var classicStatusBarView: some View {
        HStack {
            Text("合計: \(displayItems.count)件の本 / \(allItems.count)冊中")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if dropQueueRemaining > 0 {
                Text("｜ ファイルを登録中... 残り\(dropQueueRemaining)件")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Import Progress Overlay with Detailed Item Counts
    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)

                Text(importMessage)
                    .font(.body)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)

                if totalBooks > 0 {
                    // Show exact detailed current indices
                    VStack(spacing: 4) {
                        Text("書籍: \(processedBooks) / \(totalBooks) 件")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if totalPlaylists > 0 {
                            Text("シェルフ: \(processedPlaylists) / \(totalPlaylists) 件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.windowBackgroundColor)))
            .frame(width: 340)
            .shadow(radius: 12)
        }
    }

    // MARK: - Filter Evaluation Logic
    /// A cheap token that changes whenever the filtered/sorted result should
    /// be recomputed. Selection changes are intentionally NOT included, so
    /// selecting rows never re-runs the (expensive) filter+sort over 20k items.
    private var displayToken: String {
        let sidebarKey: String
        switch sidebarSelection {
        case .allBooks: sidebarKey = "all"
        case .unreadBooks: sidebarKey = "unread"
        case .shelf(let id): sidebarKey = "shelf-\(id)"
        case nil: sidebarKey = "none"
        }
        return [
            sidebarKey,
            searchText,
            keywordEquivalenceRulesJson,
            String(unreadFilterSelection),
            ratingFilterSelection.sorted().map(String.init).joined(separator: ","),
            typeFilterSelection.sorted().map(String.init).joined(separator: ","),
            sortKey.rawValue,
            String(sortAscending),
            String(allItems.count),
            String(shelves.count)
        ].joined(separator: "|")
    }

    private func computeFilteredItems() -> [Item] {
        var items = allItems

        // 1. Sidebar Selection
        if let selection = sidebarSelection {
            switch selection {
            case .allBooks:
                break
            case .unreadBooks:
                items = items.filter { $0.isUnread }
            case .shelf(let shelfID):
                if let shelf = shelves.first(where: { $0.id == shelfID }) {
                    if shelf.type == 1 {
                        let conditions = SmartConditionsCodec.decode(shelf.smartConditionsJson)
                        let now = Date()
                        items = items.filter { SmartConditionsCodec.matches($0, conditions: conditions, now: now) }
                    } else {
                        let ids = Set((shelf.items ?? []).map { $0.id })
                        items = items.filter { ids.contains($0.id) }
                    }
                }
            }
        }

        // 2. Search Text
        if !searchText.isEmpty {
            let lowerText = KeywordEquivalenceCodec.normalize(searchText)
            let rules = KeywordEquivalenceCodec.decode(keywordEquivalenceRulesJson)
            let equivalentTerms = KeywordEquivalenceCodec.searchTerms(for: searchText, rules: rules)
            items = items.filter { item in
                itemMatchesSearch(item, normalizedQuery: lowerText, equivalentTerms: equivalentTerms)
            }
        }

        // 3. Unread check filter: ALL | O
        if unreadFilterSelection == 1 {
            items = items.filter { $0.isUnread }
        }

        // 4. Rating star filter (multi-select)
        if !ratingFilterSelection.isEmpty {
            items = items.filter { ratingFilterSelection.contains($0.rating) }
        }

        // 5. Book Type filter (multi-select)
        if !typeFilterSelection.isEmpty {
            items = items.filter { typeFilterSelection.contains($0.bookType) }
        }

        // 6. Sort (右クリック > 並び替え)
        return sortItems(items)
    }

    private func itemMatchesSearch(_ item: Item, normalizedQuery: String, equivalentTerms: [KeywordEquivalenceField: [String]]) -> Bool {
        let baseValues = [
            item.title,
            item.author,
            item.genre,
            item.relation,
            item.memo,
            item.keywordA,
            item.keywordB
        ]
        if baseValues.contains(where: { KeywordEquivalenceCodec.normalize($0).contains(normalizedQuery) }) {
            return true
        }

        for (field, terms) in equivalentTerms {
            let value = KeywordEquivalenceCodec.normalize(field.value(in: item))
            if terms.contains(where: { value.contains(KeywordEquivalenceCodec.normalize($0)) }) {
                return true
            }
        }
        return false
    }

    private func sortItems(_ items: [Item]) -> [Item] {
        // Secondary key is always title for a stable, intuitive order.
        func byTitle(_ a: Item, _ b: Item) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let sorted: [Item]
        switch sortKey {
        case .title:
            sorted = items.sorted(by: byTitle)
        case .author:
            sorted = items.sorted { $0.author != $1.author
                ? $0.author.localizedStandardCompare($1.author) == .orderedAscending : byTitle($0, $1) }
        case .genre:
            sorted = items.sorted { $0.genre != $1.genre
                ? $0.genre.localizedStandardCompare($1.genre) == .orderedAscending : byTitle($0, $1) }
        case .relation:
            sorted = items.sorted { $0.relation != $1.relation
                ? $0.relation.localizedStandardCompare($1.relation) == .orderedAscending : byTitle($0, $1) }
        case .keywordA:
            sorted = items.sorted { $0.keywordA != $1.keywordA
                ? $0.keywordA.localizedStandardCompare($1.keywordA) == .orderedAscending : byTitle($0, $1) }
        case .keywordB:
            sorted = items.sorted { $0.keywordB != $1.keywordB
                ? $0.keywordB.localizedStandardCompare($1.keywordB) == .orderedAscending : byTitle($0, $1) }
        case .rating:
            sorted = items.sorted { $0.rating != $1.rating ? $0.rating < $1.rating : byTitle($0, $1) }
        case .bookType:
            sorted = items.sorted { $0.bookType != $1.bookType ? $0.bookType < $1.bookType : byTitle($0, $1) }
        case .unread:
            sorted = items.sorted { $0.isUnread != $1.isUnread ? ($0.isUnread && !$1.isUnread) : byTitle($0, $1) }
        case .addedDate:
            sorted = items.sorted { $0.addedDate != $1.addedDate ? $0.addedDate < $1.addedDate : byTitle($0, $1) }
        case .lastReadDate:
            sorted = items.sorted { ($0.lastReadDate ?? .distantPast) < ($1.lastReadDate ?? .distantPast) }
        case .pages:
            sorted = items.sorted { $0.pages != $1.pages ? $0.pages < $1.pages : byTitle($0, $1) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private func gridKeyboardStep(for width: CGFloat) -> Int {
        max(1, Int((width - 32) / 126))
    }

    private func currentEventIsShiftModified() -> Bool {
        NSApp.currentEvent?.modifierFlags.contains(.shift) == true
    }

    private func isItemSelected(_ item: Item) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    /// Moves the selection within the displayed items (keyboard nav) and keeps
    /// the newly selected row/card visible.
    private func moveSelection(by delta: Int, extending: Bool = false) {
        guard !displayItems.isEmpty else { return }
        let currentIndex = selectedDisplayIndex ?? displayItems.firstIndex { $0.id == selectedItemID } ?? -1
        let newIndex = min(max(currentIndex + delta, 0), displayItems.count - 1)
        let id = displayItems[newIndex].id
        selectedItemID = id
        selectedDisplayIndex = newIndex
        if extending {
            let anchorID = selectionAnchorItemID ?? displayItems[max(currentIndex, 0)].id
            selectionAnchorItemID = anchorID
            selectedItemIDs = selectionSet(from: anchorID, to: id)
        } else {
            selectionAnchorItemID = id
            selectedItemIDs = [id]
        }

        lastKeyboardScrollIndex = newIndex
        scrollPositionItemID = id
        prefetchNeighborCovers()
    }

    /// How many covers on each side of the cursor are warmed up in advance, so a
    /// window of 50 rows around the selection is already in memory.
    private static let coverPrefetchRadius = 25

    /// Loads the covers around the cursor into memory so the inspector image is
    /// already decoded by the time the selection reaches it.
    ///
    /// The window is built only once the cursor settles: reading 50 items out of
    /// SwiftData on every keypress would cost more on the main thread than the
    /// prefetching saves.
    private func prefetchNeighborCovers() {
        coverPrefetchTask?.cancel()
        coverPrefetchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let index = selectedDisplayIndex else { return }

            let requests = CoverPrefetchWindow
                .indices(around: index, count: displayItems.count, radius: Self.coverPrefetchRadius)
                .map { ThumbnailRequest(item: displayItems[$0]) }
            guard !requests.isEmpty, !Task.isCancelled else { return }

            await ThumbnailCache.shared.prefetch(requests)
        }
    }

    private func refreshSelectedDisplayIndex() {
        guard let selectedItemID else {
            selectedDisplayIndex = nil
            lastKeyboardScrollIndex = nil
            selectedItemIDs.removeAll()
            selectionAnchorItemID = nil
            return
        }
        selectedDisplayIndex = displayItems.firstIndex { $0.id == selectedItemID }
        guard selectedDisplayIndex != nil else {
            self.selectedItemID = nil
            selectedItemIDs.removeAll()
            selectionAnchorItemID = nil
            lastKeyboardScrollIndex = nil
            return
        }
        lastKeyboardScrollIndex = selectedDisplayIndex
        selectedItemIDs = selectedItemIDs.filter { id in
            displayItems.contains { $0.id == id }
        }
        if selectedItemIDs.isEmpty {
            selectedItemIDs = [selectedItemID]
        }
        prefetchNeighborCovers()
    }

    private func clickOverlay(for item: Item) -> some View {
        PrimaryClickOverlay { modifiers in
            selectItemFromPointer(item, modifiers: modifiers)
        } onDoubleClick: {
            openItem(item)
        }
    }

    private func selectItemFromPointer(_ item: Item, modifiers: NSEvent.ModifierFlags) {
        let isCommandClick = modifiers.contains(.command)
        if isCommandClick {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
                if selectedItemID == item.id {
                    selectedItemID = selectedItemIDs.compactMap { id in displayItems.first { $0.id == id } }.last?.id
                }
            } else {
                selectedItemIDs.insert(item.id)
                selectedItemID = item.id
                selectionAnchorItemID = selectionAnchorItemID ?? item.id
            }
        } else {
            selectedItemIDs = [item.id]
            selectedItemID = item.id
            selectionAnchorItemID = item.id
        }

        if selectedItemID == nil {
            selectedDisplayIndex = nil
            lastKeyboardScrollIndex = nil
        } else {
            selectedDisplayIndex = displayItems.firstIndex { $0.id == selectedItemID }
            lastKeyboardScrollIndex = selectedDisplayIndex
            prefetchNeighborCovers()
        }
        if !mainContentHasFocus {
            mainContentHasFocus = true
        }
    }

    private func selectionSet(from anchorID: UUID, to targetID: UUID) -> Set<UUID> {
        guard let anchorIndex = displayItems.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = displayItems.firstIndex(where: { $0.id == targetID }) else {
            return [targetID]
        }
        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(displayItems[bounds].map(\.id))
    }

private struct PrimaryClickOverlay: NSViewRepresentable {
        let onPrimaryClick: (NSEvent.ModifierFlags) -> Void
        let onDoubleClick: () -> Void

        func makeNSView(context: Context) -> ClickView {
            let view = ClickView()
            view.onPrimaryClick = onPrimaryClick
            view.onDoubleClick = onDoubleClick
            return view
        }

        func updateNSView(_ nsView: ClickView, context: Context) {
            nsView.onPrimaryClick = onPrimaryClick
            nsView.onDoubleClick = onDoubleClick
        }

        final class ClickView: NSView {
            var onPrimaryClick: ((NSEvent.ModifierFlags) -> Void)?
            var onDoubleClick: (() -> Void)?

            override var acceptsFirstResponder: Bool { true }

            override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
                true
            }

            override func hitTest(_ point: NSPoint) -> NSView? {
                guard let event = window?.currentEvent else {
                    return super.hitTest(point)
                }
                switch event.type {
                case .leftMouseDown:
                    return super.hitTest(point)
                default:
                    return nil
                }
            }

            override func mouseDown(with event: NSEvent) {
                onPrimaryClick?(event.modifierFlags)
                if event.clickCount >= 2 {
                    onDoubleClick?()
                }
            }
        }
    }

    private struct SplitViewAutosave: NSViewRepresentable {
        let name: String

        func makeNSView(context: Context) -> AutosaveHostView {
            let view = AutosaveHostView()
            view.autosaveName = name
            return view
        }

        func updateNSView(_ nsView: AutosaveHostView, context: Context) {
            nsView.autosaveName = name
            nsView.installAutosaveName()
        }

        final class AutosaveHostView: NSView {
            var autosaveName = ""

            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                installAutosaveName()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                installAutosaveName()
            }

            func installAutosaveName() {
                guard !autosaveName.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          let splitView = self.enclosingSplitView() else {
                        return
                    }
                    splitView.autosaveName = NSSplitView.AutosaveName(self.autosaveName)
                }
            }

            private func enclosingSplitView() -> NSSplitView? {
                var view = superview
                while let current = view {
                    if let splitView = current as? NSSplitView {
                        return splitView
                    }
                    view = current.superview
                }
                return nil
            }
        }
    }

    /// Toggles direction when re-selecting the current key, else switches key.
    private func applySort(_ key: ItemSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    // MARK: - Drag and Drop Handlers (batch queue)
    private func handleFileDrop(providers: [NSItemProvider], targetShelfID: UUID? = nil) {
        Task { @MainActor in
            // 1. Collect all dropped URLs first
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let url {
                    urls.append(url)
                }
            }

            // 2. Register sequentially with progress in the status bar
            dropQueueRemaining = urls.count
            var lastAddedID: UUID? = nil

            for url in urls {
                defer { dropQueueRemaining -= 1 }

                var isDir: ObjCBool = false
                let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard fileExists, let kind = droppedFileKind(for: url, isDirectory: isDir.boolValue) else { continue }

                if let id = addDroppedFile(url: url, kind: kind, targetShelfID: targetShelfID) {
                    lastAddedID = id
                }
                // Yield so the UI (progress counter) stays responsive
                await Task.yield()
            }

            try? modelContext.save()
            if let lastAddedID {
                selectedItemID = lastAddedID
                selectedItemIDs = [lastAddedID]
                selectionAnchorItemID = lastAddedID
            }
            displayItems = computeFilteredItems()
            refreshSelectedDisplayIndex()
        }
    }

    private func currentStaticShelfID() -> UUID? {
        guard case .shelf(let shelfID) = sidebarSelection,
              shelves.contains(where: { $0.id == shelfID && $0.type == 0 }) else {
            return nil
        }
        return shelfID
    }

    private func droppedFileKind(for url: URL, isDirectory: Bool) -> DroppedFileKind? {
        if isDirectory { return .folder }

        let ext = url.pathExtension.lowercased()
        if ["zip", "rar", "7z"].contains(ext), ext == "zip" || helperExtensionIsRegistered(ext) {
            return .pageCountedArchive
        }

        if helperExtensionIsRegistered(ext) {
            return .helperFile
        }

        return nil
    }

    /// Registers a single dropped file. Returns the Item id if newly added.
    @discardableResult
    private func addDroppedFile(url: URL, kind: DroppedFileKind, targetShelfID: UUID?) -> UUID? {
        let (volumePath, volumeName, relativePath) = PathParser.split(url.path)

        // Prevent duplicate (Merge logic). Re-dropping an existing item also
        // repairs its access permission via a fresh security-scoped bookmark.
        let fetchDescriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.relativePath == relativePath })
        if let existing = try? modelContext.fetch(fetchDescriptor).first {
            existing.bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            addToStaticShelfIfNeeded(existing, shelfID: targetShelfID)
            if existing.pages == 0 {
                schedulePageCountRefreshIfNeeded(
                    itemID: existing.id,
                    url: url,
                    kind: kind,
                    shouldApplyAutoBookType: false
                )
            }
            return existing.id
        }

        // Find or create Volume
        let volFetch = FetchDescriptor<Volume>(predicate: #Predicate { $0.lastKnownPath == volumePath })
        let volume: Volume
        if let existingVol = try? modelContext.fetch(volFetch).first {
            volume = existingVol
        } else {
            let newVol = Volume(name: volumeName, lastKnownPath: volumePath)
            modelContext.insert(newVol)
            volume = newVol
        }

        // Create new blank item dynamically from D&D drop!
        // The drop grants sandbox access to this URL right now, so persist an
        // item-level security-scoped bookmark for future launches.
        let itemBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        // Parse 「(ジャンル)[作者名]タイトル」 from the file name
        let parsed = FileNameParser.parse(fileName: url.lastPathComponent, format: customRenameFormat)
        let title = parsed.title.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.title
        let parsedBookType = bookTypeIndex(for: parsed.type)
        let selectedBookType = parsedBookType ?? (kind == .helperFile ? 5 : 0)

        let itemID = UUID()
        let newItem = Item(
            id: itemID,
            volume: volume,
            relativePath: relativePath,
            bookmarkData: itemBookmark,
            title: title,
            author: parsed.author,
            genre: parsed.genre,
            relation: parsed.relation,
            keywordA: parsed.keywordA,
            keywordB: parsed.keywordB,
            pages: 0,
            bookType: selectedBookType,
            fileType: kind.fileType
        )

        modelContext.insert(newItem)
        addToStaticShelfIfNeeded(newItem, shelfID: targetShelfID)
        schedulePageCountRefreshIfNeeded(
            itemID: itemID,
            url: url,
            kind: kind,
            shouldApplyAutoBookType: parsedBookType == nil
        )
        return newItem.id
    }

    private func schedulePageCountRefreshIfNeeded(
        itemID: UUID,
        url: URL,
        kind: DroppedFileKind,
        shouldApplyAutoBookType: Bool
    ) {
        guard kind.shouldUsePageCountForBookType else { return }

        Task {
            let update = await Task.detached(priority: .utility) {
                DroppedFilePageCountUpdate(
                    itemID: itemID,
                    pageCount: ItemFileAccess.listPages(at: url).count,
                    shouldApplyAutoBookType: shouldApplyAutoBookType
                )
            }.value
            applyPageCountUpdate(update)
        }
    }

    private func applyPageCountUpdate(_ update: DroppedFilePageCountUpdate) {
        guard let item = allItems.first(where: { $0.id == update.itemID }) else { return }
        item.pages = update.pageCount
        if update.shouldApplyAutoBookType,
           let autoBookType = BookTypeAutoClassifier.classify(pageCount: update.pageCount) {
            item.bookType = autoBookType
        }
        try? modelContext.save()
        displayItems = computeFilteredItems()
        refreshSelectedDisplayIndex()
    }

    /// A dropped file should be registered in the library and added to the
    /// normal shelf that was targeted when the drop started. Smart shelves are
    /// condition-based, so they remain automatic and are not manually mutated.
    private func addToStaticShelfIfNeeded(_ item: Item, shelfID: UUID?) {
        guard let shelfID,
              let shelf = shelves.first(where: { $0.id == shelfID && $0.type == 0 }) else {
            return
        }

        var shelfItems = shelf.items ?? []
        guard !shelfItems.contains(where: { $0.id == item.id }) else { return }
        shelfItems.append(item)
        shelf.items = shelfItems
    }

    private func bookTypeIndex(for parsedType: String) -> Int? {
        let trimmed = parsedType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return typeNames.firstIndex { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func runMaintenanceAction(_ action: MaintenanceAction) {
        switch action {
        case .manageVolumes:
            showVolumeManager = true
        case .importXMLLibrary:
            importXMLLibrary()
        case .migrateLegacyThumbnails:
            migrateLegacyThumbnails()
        case .repairThumbnails:
            repairThumbnails()
        case .repairEmptyTitles:
            repairEmptyTitles()
        }
    }

    // MARK: - Library Import & Merge Action with Progress Tracking
    private func importXMLLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.xml, .propertyList]
        panel.title = "Stackroom Library.xml をマージインポート"

        if panel.runModal() == .OK, let url = panel.url {
            // Under the App Sandbox the legacy thumbnails folder must be granted
            // explicitly. Ask once here (cancel = import without thumbnails).
            let legacyAssetsRoot = askForLegacyAssetsFolder()

            isImporting = true
            importMessage = "ライブラリXMLを展開しています..."
            totalBooks = 0
            processedBooks = 0
            totalPlaylists = 0
            processedPlaylists = 0

            Task {
                let container = modelContext.container
                let importer = LibraryImporter(modelContainer: container)

                do {
                    let results = try await importer.importLibrary(from: url, legacyAssetsRoot: legacyAssetsRoot) { pBooks, tBooks, pPlays, tPlays in
                        // Real-time detailed counts update callback!
                        self.totalBooks = tBooks
                        self.processedBooks = pBooks
                        self.totalPlaylists = tPlays
                        self.processedPlaylists = pPlays
                        if pPlays > 0 {
                            self.importMessage = "シェルフをインポート中..."
                        } else if pBooks > 0 {
                            self.importMessage = "書籍とサムネイル画像をインポート中..."
                        }
                    }

                    await MainActor.run {
                        self.importMessage = "マージインポートが完了しました！\n\nマージ処理件数:\n・新しく追加された本: \(results.booksCount)冊\n・追加されたシェルフ: \(results.playlistsCount)個"
                        self.isImporting = false
                        self.showImportResult = true
                    }
                } catch {
                    await MainActor.run {
                        self.importMessage = "インポートに失敗しました:\n\(error.localizedDescription)"
                        self.isImporting = false
                        self.showImportResult = true
                    }
                }
            }
        }
    }

    /// Asks the user to select the legacy "Stackroom Library" thumbnails folder
    /// so the sandboxed app can migrate `[ID]/thumbnail.jpg` assets.
    /// Returns nil when the user cancels (= skip thumbnail migration).
    private func askForLegacyAssetsFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Stackroomサムネイルフォルダの選択"
        panel.message = "表紙サムネイルを移行するには、Stackroomの「Stackroom Library」フォルダを選択してください。（キャンセルするとサムネイルなしでインポートします）"
        panel.prompt = "このフォルダを移行"
        // The real (non-container) legacy location as the starting point
        panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Application Support/Stackroom")

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Bulk-copies legacy `[ID]/thumbnail.jpg` assets into the app's thumbnail
    /// cache for ALL items with a legacy ID (works for already-imported items,
    /// unlike the copy that runs during XML import).
    private func migrateLegacyThumbnails() {
        guard let root = askForLegacyAssetsFolder() else { return }

        // Snapshot (legacyID, itemID) pairs so the background task doesn't touch models
        let pairs: [(legacyID: Int, itemID: UUID)] = allItems.compactMap { item in
            item.legacyID.map { ($0, item.id) }
        }

        isImporting = true
        importMessage = "サムネイル画像を移行しています..."
        totalBooks = pairs.count
        processedBooks = 0
        totalPlaylists = 0
        processedPlaylists = 0

        Task.detached(priority: .userInitiated) {
            let scoped = root.startAccessingSecurityScopedResource()
            defer {
                if scoped { root.stopAccessingSecurityScopedResource() }
            }

            let cacheDir = ThumbnailCache.diskCacheDirectory
            let fileManager = FileManager.default
            var copied = 0
            var missing = 0

            for (index, pair) in pairs.enumerated() {
                let source = root.appendingPathComponent("\(pair.legacyID)/thumbnail.jpg")
                let destination = cacheDir.appendingPathComponent("\(pair.itemID.uuidString).jpg")

                if fileManager.fileExists(atPath: destination.path) {
                    // already migrated
                } else if fileManager.fileExists(atPath: source.path) {
                    try? fileManager.copyItem(at: source, to: destination)
                    copied += 1
                } else {
                    missing += 1
                }

                if index % 200 == 0 {
                    let current = index
                    await MainActor.run {
                        self.processedBooks = current
                    }
                }
            }

            let copiedCount = copied
            let missingCount = missing
            await MainActor.run {
                self.isImporting = false
                self.importMessage = "サムネイル移行が完了しました。\n\n・コピーした画像: \(copiedCount)件\n・旧アセットが見つからない本: \(missingCount)件"
                self.showImportResult = true
                // Reload all visible covers
                NotificationCenter.default.post(name: .coverDidChange, object: nil)
            }
        }
    }

    /// Bulk thumbnail repair: landscape thumbnails (width > height) are likely
    /// garbage picks. For those items the cover is re-extracted using the
    /// sequential-numbering heuristic (lowest number of the largest 連番 group).
    private func repairThumbnails() {
        let items = allItems
        isImporting = true
        importMessage = "サムネイルを検査・修正しています..."
        totalBooks = items.count
        processedBooks = 0
        totalPlaylists = 0
        processedPlaylists = 0

        Task {
            let cacheDir = ThumbnailCache.diskCacheDirectory
            let scanResult = await Task.detached(priority: .userInitiated) {
                await Self.scanThumbnailRepairTargets(itemIDs: items.map(\.id), cacheDir: cacheDir)
            }.value

            let suspectIDs = Set(scanResult.itemIDs)
            let suspectItems = items.filter { suspectIDs.contains($0.id) }
            let monochromeSuspects = scanResult.monochromeCount
            let landscapeSuspects = scanResult.landscapeCount
            let missingThumbnails = scanResult.missingCount
            totalBooks = suspectItems.count
            processedBooks = 0

            // Capture what the workers need while still on the main actor: the
            // SwiftData models cannot be read from the tasks doing the extraction.
            let requests = suspectItems.map { ThumbnailRequest(item: $0) }

            let outcome = await ThumbnailCache.generateThumbnails(for: requests) { completed in
                processedBooks = completed
            }
            let repaired = outcome.generated
            let failed = outcome.failed

            // The covers just regenerated may still be in memory under their old
            // contents; drop that tier so the reload below reads the new files.
            await ThumbnailCache.shared.invalidateMemoryCache()

            isImporting = false
            processedBooks = totalBooks
            importMessage = "サムネイルの一括生成が完了しました。\n\n・未生成: \(missingThumbnails)件\n・モノクロ: \(monochromeSuspects)件\n・横長（ゴミ画像疑い）: \(landscapeSuspects)件\n・生成済み: \(repaired)件\n・生成できず（未接続など）: \(failed)件"
            showImportResult = true
            NotificationCenter.default.post(name: .coverDidChange, object: nil)
        }
    }

    nonisolated private static func scanThumbnailRepairTargets(itemIDs: [UUID], cacheDir: URL) async -> ThumbnailRepairScanResult {
        guard !itemIDs.isEmpty else { return ThumbnailRepairScanResult() }

        let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunkSize = max(100, itemIDs.count / max(1, workerCount * 2))

        return await withTaskGroup(of: ThumbnailRepairScanResult.self) { group in
            for start in stride(from: 0, to: itemIDs.count, by: chunkSize) {
                let end = min(start + chunkSize, itemIDs.count)
                let chunk = Array(itemIDs[start..<end])
                group.addTask(priority: .utility) {
                    var result = ThumbnailRepairScanResult()
                    for itemID in chunk {
                        let thumbURL = cacheDir.appendingPathComponent("\(itemID.uuidString).jpg")
                        guard let reasons = thumbnailRepairReasons(at: thumbURL) else { continue }
                        result.itemIDs.append(itemID)
                        if reasons.isMonochrome {
                            result.monochromeCount += 1
                        }
                        if reasons.isLandscape {
                            result.landscapeCount += 1
                        }
                        if reasons.isMissing {
                            result.missingCount += 1
                        }
                    }
                    return result
                }
            }

            var merged = ThumbnailRepairScanResult()
            for await result in group {
                merged = merged.merged(with: result)
            }
            return merged
        }
    }

    nonisolated static func thumbnailRepairReasons(at thumbURL: URL) -> (isMonochrome: Bool, isLandscape: Bool, isMissing: Bool)? {
        // No thumbnail yet, or one that cannot be read back: the cover has to be
        // generated. Without this, browsing is the only thing that ever fills the
        // cache, one archive at a time, and rows the cursor passes stay blank.
        guard FileManager.default.fileExists(atPath: thumbURL.path),
              let size = CoverSelector.imagePixelSize(at: thumbURL) else {
            return (isMonochrome: false, isLandscape: false, isMissing: true)
        }

        if size.width > size.height {
            return (isMonochrome: false, isLandscape: true, isMissing: false)
        }

        if CoverSelector.imageIsMonochrome(at: thumbURL) {
            return (isMonochrome: true, isLandscape: false, isMissing: false)
        }

        return nil
    }

    /// Fills empty display metadata by parsing the file name with the
    /// customizable format. Falls back to the classic
    /// 「(ジャンル)[作者名]タイトル.zip」 naming convention.
    private func repairEmptyTitles() {
        var updated = 0

        for item in allItems {
            guard item.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let fileName = (item.relativePath as NSString).lastPathComponent
            let parsed = FileNameParser.parse(fileName: fileName, format: customRenameFormat)

            // Never leave the title empty: fall back to the bare file name
            let newTitle = parsed.title.isEmpty
                ? (fileName as NSString).deletingPathExtension
                : parsed.title
            guard !newTitle.isEmpty else { continue }

            item.title = newTitle
            if item.author.isEmpty { item.author = parsed.author }
            if item.genre.isEmpty { item.genre = parsed.genre }
            if item.relation.isEmpty { item.relation = parsed.relation }
            if item.keywordA.isEmpty { item.keywordA = parsed.keywordA }
            if item.keywordB.isEmpty { item.keywordB = parsed.keywordB }
            if let parsedBookType = bookTypeIndex(for: parsed.type) {
                item.bookType = parsedBookType
            }
            updated += 1
        }

        try? modelContext.save()
        importMessage = "タイトルの補完が完了しました。\n\n・ファイル名から補完した本: \(updated)件"
        showImportResult = true
    }

    // MARK: - Item Context Menu (right-click, classic Stackroom)
    @ViewBuilder
    private func itemContextMenu(_ item: Item) -> some View {
        Button("スライドショー") { startSlideshow(item) }
        Button("このヘルパーで開く") { openItem(item) }

        Divider()

        Button("削除") { deleteItem(item, trashFile: false) }
        Button("ゴミ箱に入れる...") { deleteItem(item, trashFile: true) }

        Menu("レート") {
            Button("なし") { item.rating = 0; try? modelContext.save() }
            ForEach(1...5, id: \.self) { r in
                Button(String(repeating: "★", count: r)) { item.rating = r; try? modelContext.save() }
            }
        }

        Menu("種類") {
            ForEach(0..<BookTypeInfo.count, id: \.self) { idx in
                Button(typeNames[idx]) { item.bookType = idx; try? modelContext.save() }
            }
        }

        Button("未読チェック") { item.isUnread.toggle(); try? modelContext.save() }

        Divider()

        Button("Finderで表示") { revealInFinder(item) }
        Button("ファイルを移動...") { moveItemFile(item) }
        Button("ファイルをリネーム...") { renameItemFile(item) }
        Button("表紙を編集...") {
            selectedItemID = item.id
            selectedItemIDs = [item.id]
            selectionAnchorItemID = item.id
            showCoverEditor = true
        }
        Button("ファイルを再指定...") { reassignItemFile(item) }

        Divider()

        Menu("並び替え") {
            ForEach(ItemSortKey.allCases) { key in
                Button {
                    applySort(key)
                } label: {
                    if sortKey == key {
                        Label(key.label, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(key.label)
                    }
                }
            }
        }
    }

    // MARK: - File Operations (move / rename / reassign / trash)

    private func selectedItemsForAction() -> [Item] {
        let selectedIDs = selectedItemIDs.isEmpty
            ? Set(selectedItemID.map { [$0] } ?? [])
            : selectedItemIDs
        return displayItems.filter { selectedIDs.contains($0.id) }
    }

    private func deleteSelectedItemsFromKeyboard() {
        let items = selectedItemsForAction()
        guard !items.isEmpty else { return }

        if case .shelf(let shelfID) = sidebarSelection,
           let shelf = shelves.first(where: { $0.id == shelfID && $0.type == 0 }) {
            remove(items, from: shelf)
        } else {
            deleteItemsFromLibrary(items)
        }
    }

    private func remove(_ items: [Item], from shelf: Shelf) {
        let ids = Set(items.map(\.id))
        shelf.items = (shelf.items ?? []).filter { !ids.contains($0.id) }
        clearSelection(afterRemoving: ids)
        try? modelContext.save()
        displayItems = computeFilteredItems()
        refreshSelectedDisplayIndex()
    }

    private func deleteItemsFromLibrary(_ items: [Item]) {
        let ids = Set(items.map(\.id))
        for item in items {
            modelContext.delete(item)
        }
        clearSelection(afterRemoving: ids)
        try? modelContext.save()
        displayItems = computeFilteredItems()
        refreshSelectedDisplayIndex()
    }

    private func clearSelection(afterRemoving removedIDs: Set<UUID>) {
        selectedItemIDs.subtract(removedIDs)
        if let selectedItemID, removedIDs.contains(selectedItemID) {
            self.selectedItemID = selectedItemIDs.compactMap { id in displayItems.first { $0.id == id } }.first?.id
        }
        if let selectionAnchorItemID, removedIDs.contains(selectionAnchorItemID) {
            self.selectionAnchorItemID = selectedItemID
        }
    }

    /// Deletes an item from the library. When trashFile is true the actual
    /// file is also moved to the Trash.
    private func deleteItem(_ item: Item, trashFile: Bool) {
        if trashFile, let resolved = ItemFileAccess.resolve(item: item) {
            do {
                try FileManager.default.trashItem(at: resolved.url, resultingItemURL: nil)
            } catch {
                openErrorMessage = "ファイルをゴミ箱に移動できませんでした。\n\n\(error.localizedDescription)"
            }
            resolved.release()
        }
        clearSelection(afterRemoving: [item.id])
        modelContext.delete(item)
        try? modelContext.save()
        displayItems = computeFilteredItems()
        refreshSelectedDisplayIndex()
    }

    /// Moves the item's file into a user-selected folder, updating its
    /// volume / relative path / bookmark.
    private func moveItemFile(_ item: Item) {
        guard let resolved = ItemFileAccess.resolve(item: item) else {
            showMissingFileAlert = true
            return
        }
        let sourceURL = resolved.url
        defer { resolved.release() }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "移動先フォルダを選択"
        panel.prompt = "ここへ移動"

        guard panel.runModal() == .OK, let destDir = panel.url else { return }
        let scoped = destDir.startAccessingSecurityScopedResource()
        defer { if scoped { destDir.stopAccessingSecurityScopedResource() } }

        let destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            updateItemLocation(item, to: destURL)
        } catch {
            openErrorMessage = "ファイルを移動できませんでした。\n\n\(error.localizedDescription)"
        }
    }

    /// Renames the item's file on disk (keeping it in the same folder).
    private func renameItemFile(_ item: Item) {
        guard let resolved = ItemFileAccess.resolve(item: item) else {
            showMissingFileAlert = true
            return
        }
        let sourceURL = resolved.url
        defer { resolved.release() }

        let currentName = sourceURL.lastPathComponent
        guard let newName = promptForText(
            title: "ファイルをリネーム",
            message: "新しいファイル名を入力してください。",
            defaultValue: currentName
        )?.trimmingCharacters(in: .whitespaces), !newName.isEmpty, newName != currentName else {
            return
        }

        let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            updateItemLocation(item, to: destURL)
        } catch {
            openErrorMessage = "ファイル名を変更できませんでした。\n\n\(error.localizedDescription)"
        }
    }

    /// Re-points the item at a different file/folder the user selects
    /// (「ファイルを再指定...」), e.g. when the original was moved manually.
    private func reassignItemFile(_ item: Item) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "この本に対応するファイルを選択"
        panel.prompt = "再指定"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        updateItemLocation(item, to: url)
    }

    /// Updates an item's volume / relative path / security-scoped bookmark to
    /// point at `url`. The caller must hold security-scoped access to `url`.
    private func updateItemLocation(_ item: Item, to url: URL) {
        let (volumePath, volumeName, relativePath) = PathParser.split(url.path)

        let volFetch = FetchDescriptor<Volume>(predicate: #Predicate { $0.lastKnownPath == volumePath })
        let volume: Volume
        if let existingVol = try? modelContext.fetch(volFetch).first {
            volume = existingVol
        } else {
            let newVol = Volume(name: volumeName, lastKnownPath: volumePath)
            modelContext.insert(newVol)
            volume = newVol
        }

        item.volume = volume
        item.relativePath = relativePath
        item.bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        try? modelContext.save()

        // Refresh the cover from the new location
        NotificationCenter.default.post(name: .coverDidChange, object: item.id)
    }

    /// Shows a simple modal text-input prompt (AppKit NSAlert accessory).
    private func promptForText(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - App Actions
    private func deleteSelectedItem() {
        guard let item = selectedItem else { return }
        modelContext.delete(item)
        try? modelContext.save()
        selectedItemID = nil
        selectedItemIDs.removeAll()
        selectionAnchorItemID = nil
    }

    private func deleteShelf(_ shelf: Shelf) {
        let type = shelf.type
        if case .shelf(let id) = sidebarSelection, id == shelf.id {
            sidebarSelection = .allBooks
        }
        modelContext.delete(shelf)
        try? modelContext.save()
        normalizeShelfOrder(type: type)
    }

    private func reorderShelfByDrag(sourceID: UUID, targetID: UUID, type: Int) {
        var orderIDs = shelfOrderIDs(type: type)
        if orderIDs.isEmpty {
            orderIDs = orderedShelves(type: type).map(\.id)
        }

        guard let sourceIndex = orderIDs.firstIndex(of: sourceID),
              let targetIndex = orderIDs.firstIndex(of: targetID),
              sourceIndex != targetIndex else {
            return
        }

        let movedShelfID = orderIDs.remove(at: sourceIndex)
        orderIDs.insert(movedShelfID, at: targetIndex)

        if type == 0 {
            staticShelfOrderIDs = orderIDs
        } else {
            smartShelfOrderIDs = orderIDs
        }
    }

    private func commitShelfDrag(type: Int) {
        let orderIDs = shelfOrderIDs(type: type)
        let byID = Dictionary(uniqueKeysWithValues: shelves.filter { $0.type == type }.map { ($0.id, $0) })
        let ordered = orderIDs.compactMap { byID[$0] }
        guard !ordered.isEmpty else { return }
        applyShelfOrder(ordered)
    }

    private func normalizeShelfOrder(type: Int) {
        applyShelfOrder(orderedShelves(type: type))
    }

    private func applyShelfOrder(_ ordered: [Shelf]) {
        for (index, shelf) in ordered.enumerated() {
            shelf.sortOrder = index * 10
        }
        try? modelContext.save()
    }

    private func nextShelfSortOrder(type: Int) -> Int {
        let existing = orderedShelves(type: type)
        guard let last = existing.last else { return 0 }
        return last.sortOrder + 10
    }

    /// Starts a slideshow for the item (toolbar スライドショー button) by
    /// launching the external slideshow helper with the file's full path.
    private func startSlideshow(_ item: Item) {
        guard let resolved = openableFile(for: item) else { return }

        guard let appURL = helperAppURL(fullPath: slideshowHelperFullPath, name: slideshowHelperName) else {
            resolved.release()
            openErrorMessage = "スライドショーで開くための外部ビューアが設定されていません。\n\n環境設定 > スライドショー で「スライドショーヘルパー」を指定してください。"
            return
        }
        open(fileURL: resolved.url, withApp: appURL, releasing: resolved)
        markRead(item)
    }

    /// Opens an item (double-click / このヘルパーで開く) with an external app:
    /// extension helper → ZIP helper (.zip) → slideshow helper (folder) →
    /// system default. This app has no built-in viewer.
    private func openItem(_ item: Item) {
        guard let resolved = openableFile(for: item) else { return }
        let fileURL = resolved.url
        let ext = fileURL.pathExtension.lowercased()

        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)

        // 1. Extension-specific helper (環境設定 > ヘルパー)
        if !ext.isEmpty, let appURL = helperApp(forExtension: ext) {
            open(fileURL: fileURL, withApp: appURL, releasing: resolved)
            markRead(item)
            return
        }

        // 2. ZIP: external ZIP archive helper
        if ext == "zip" {
            guard let appURL = helperAppURL(fullPath: zipHelperFullPath, name: zipHelperName) else {
                resolved.release()
                openErrorMessage = "Zip アーカイブを開くための外部ビューアが設定されていません。\n\n環境設定 > スライドショー で「Zip アーカイブヘルパー」を指定してください。"
                return
            }
            open(fileURL: fileURL, withApp: appURL, releasing: resolved)
            markRead(item)
            return
        }

        // 3. Image folder: external slideshow helper
        if isDir.boolValue {
            guard let appURL = helperAppURL(fullPath: slideshowHelperFullPath, name: slideshowHelperName) else {
                resolved.release()
                openErrorMessage = "画像フォルダを開くための外部ビューアが設定されていません。\n\n環境設定 > スライドショー で「スライドショーヘルパー」を指定してください。"
                return
            }
            open(fileURL: fileURL, withApp: appURL, releasing: resolved)
            markRead(item)
            return
        }

        // 4. Anything else: system default application
        if !NSWorkspace.shared.open(fileURL) {
            openErrorMessage = "システムデフォルトのアプリケーションで「\(fileURL.lastPathComponent)」を開けませんでした。"
        }
        releaseLater(resolved)
        markRead(item)
    }

    /// Resolves an item's file and verifies read access, showing the missing
    /// file alert (with diagnostics) on failure. Caller owns the returned file.
    private func openableFile(for item: Item) -> ResolvedItemFile? {
        guard let resolved = ItemFileAccess.resolve(item: item) else {
            missingFileDetail = diagnostic(for: item, resolved: nil, reason: "ファイルの場所を解決できません（ボリューム/ブックマーク未設定）")
            showMissingFileAlert = true
            return nil
        }
        if !FileManager.default.fileExists(atPath: resolved.url.path) {
            missingFileDetail = diagnostic(for: item, resolved: resolved, reason: "その場所にファイルが存在しません")
            resolved.release()
            showMissingFileAlert = true
            return nil
        }
        if !FileManager.default.isReadableFile(atPath: resolved.url.path) {
            missingFileDetail = diagnostic(for: item, resolved: resolved, reason: "アクセス権がありません（サンドボックス）")
            resolved.release()
            showMissingFileAlert = true
            return nil
        }
        return resolved
    }

    /// Builds a diagnostic string to help pinpoint why a file could not open.
    private func diagnostic(for item: Item, resolved: ResolvedItemFile?, reason: String) -> String {
        let volume = item.volume
        return """
        [診断情報]
        理由: \(reason)
        ボリューム名: \(volume?.name ?? "（なし）")
        マウントパス: \(volume?.lastKnownPath ?? "-")
        ボリュームのアクセス権: \(volume?.bookmarkData != nil ? "保存済み" : "未保存")
        アイテム個別のアクセス権: \(item.bookmarkData != nil ? "あり" : "なし")
        相対パス: \(item.relativePath)
        解決したフルパス: \(resolved?.url.path ?? "-")
        """
    }

    private func markRead(_ item: Item) {
        item.isUnread = false
        item.lastReadDate = Date()
    }

    private func open(fileURL: URL, withApp appURL: URL, releasing resolved: ResolvedItemFile) {
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error {
                    // Surface helper launch failures instead of failing silently
                    openErrorMessage = "「\(appURL.deletingPathExtension().lastPathComponent)」で「\(fileURL.lastPathComponent)」を開けませんでした。\n\n\(error.localizedDescription)"
                }
                releaseLater(resolved)
            }
        }
    }

    /// Keeps security-scoped access alive briefly so the external viewer can
    /// open the file, then releases it.
    private func releaseLater(_ resolved: ResolvedItemFile) {
        Task {
            try? await Task.sleep(for: .seconds(10))
            resolved.release()
        }
    }

    /// Looks up a helper application registered for a file extension
    /// (環境設定 > ヘルパー tab lists).
    private func helperApp(forExtension ext: String) -> URL? {
        let extLines = helperExtensionsList.components(separatedBy: "\n")
        let appLines = helperApplicationsList.components(separatedBy: "\n")

        for (idx, line) in extLines.enumerated() {
            if helperExtensions(in: line).contains(normalizedExtension(ext)), idx < appLines.count {
                return helperAppURL(fullPath: appLines[idx], name: appLines[idx])
            }
        }
        return nil
    }

    private func helperExtensionIsRegistered(_ ext: String) -> Bool {
        let normalized = normalizedExtension(ext)
        guard !normalized.isEmpty else { return false }
        return helperExtensionsList
            .components(separatedBy: "\n")
            .contains { helperExtensions(in: $0).contains(normalized) }
    }

    private func helperExtensions(in line: String) -> [String] {
        line.components(separatedBy: ",")
            .map { normalizedExtension($0) }
            .filter { !$0.isEmpty }
    }

    private func normalizedExtension(_ ext: String) -> String {
        ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    /// Resolves a helper app reference (full path preferred, plain app name as fallback).
    private func helperAppURL(fullPath: String, name: String) -> URL? {
        if !fullPath.isEmpty, fullPath.hasPrefix("/"), FileManager.default.fileExists(atPath: fullPath) {
            return URL(fileURLWithPath: fullPath)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }
        let candidates = [
            "/Applications/\(trimmedName).app",
            NSHomeDirectory() + "/Applications/\(trimmedName).app"
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private func revealInFinder(_ item: Item) {
        guard let resolved = ItemFileAccess.resolve(item: item) else { return }
        NSWorkspace.shared.selectFile(resolved.url.path, inFileViewerRootedAtPath: "")
        releaseLater(resolved)
    }

    private func createStaticShelf() {
        let newShelf = Shelf(title: "新規シェルフ", icon: 0, type: 0, sortOrder: nextShelfSortOrder(type: 0))
        modelContext.insert(newShelf)
        try? modelContext.save()

        var orderIDs = staticShelfOrderIDs.isEmpty ? orderedShelves(type: 0).map(\.id) : staticShelfOrderIDs
        orderIDs.removeAll { $0 == newShelf.id }
        orderIDs.append(newShelf.id)
        staticShelfOrderIDs = orderIDs

        sidebarSelection = .shelf(newShelf.id)
        editingShelfID = newShelf.id
        editingShelfTitle = newShelf.title
        pendingSidebarScrollShelfID = newShelf.id
    }

    private func commitEditingShelfTitle(_ shelf: Shelf) {
        let trimmedTitle = editingShelfTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        shelf.title = trimmedTitle.isEmpty ? "新規シェルフ" : trimmedTitle
        try? modelContext.save()
        editingShelfID = nil
        editingShelfTitle = ""
        focusedShelfTitleID = nil
    }

    // MARK: - Dialog views
    private var importResultView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)

            Text("インポート処理完了")
                .font(.title3)
                .fontWeight(.bold)

            Text(importMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("OK") {
                showImportResult = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360, height: 260)
    }
}
