//
//  ContentView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum SidebarSelection: Hashable {
    case allBooks
    case unreadBooks
    case shelf(UUID)
}

/// Inspector text fields that can receive stamps (スタンプ) input.
enum InspectorField: Hashable {
    case title, author, keywordA, keywordB, memo, genre, relation
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

    // DB Queries
    @Query(sort: \Volume.name) private var volumes: [Volume]
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

    @AppStorage("advancedPasswordLockEnabled") private var lockEnabled = false
    @AppStorage("advancedPasswordValue") private var passwordValue = ""

    // Viewer helper settings (環境設定 > スライドショー / ヘルパー)
    @AppStorage("slideshowHelperPath") private var slideshowHelperName = ""
    @AppStorage("slideshowHelperFullPath") private var slideshowHelperFullPath = ""
    @AppStorage("zipHelperPath") private var zipHelperName = ""
    @AppStorage("zipHelperFullPath") private var zipHelperFullPath = ""
    @AppStorage("helperExtensionsList") private var helperExtensionsList = "mov, avi, mpg\nrar"
    @AppStorage("helperApplicationsList") private var helperApplicationsList = "\n"

    // UI Selection and view states
    @State private var sidebarSelection: SidebarSelection? = .allBooks
    @State private var selectedItemID: UUID? = nil
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
    @State private var showSmartShelfEditor = false
    @State private var editingSmartShelf: Shelf? = nil
    @State private var showCoverEditor = false
    @State private var showMissingFileAlert = false
    @State private var missingFileDetail = ""
    @State private var openErrorMessage: String? = nil

    // Drag & drop batch registration state
    @State private var dropQueueRemaining = 0

    // Inspector focus (stamps target)
    @FocusState private var focusedField: InspectorField?
    @FocusState private var mainContentHasFocus: Bool

    private var selectedItem: Item? {
        guard let selectedID = selectedItemID else { return nil }
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

    var body: some View {
        ZStack {
            if isLocked {
                // Classic Password Lock Screen
                passwordLockScreen
            } else {
                // Main Application Window (Classic 3-Pane Structure)
                VStack(spacing: 0) {
                    // 1. Classic Toolbar Header (buttons left, filters center, search right)
                    classicToolbarView

                    Divider()

                    // 2. Main Navigation Split view
                    NavigationSplitView {
                        sidebarPane
                            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
                    } content: {
                        mainContentPane
                            .navigationSplitViewColumnWidth(min: 400, ideal: 550)
                    } detail: {
                        detailPane
                            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
                    }

                    Divider()

                    // 3. Classic Status Bar (Bottom bar showing item count)
                    classicStatusBarView
                }
            }
        }
        .sheet(isPresented: $showVolumeManager) {
            VolumeRelocationView(isPresented: $showVolumeManager)
        }
        .sheet(isPresented: $showImportResult) {
            importResultView
        }
        .sheet(isPresented: $showSmartShelfEditor) {
            SmartShelfEditorView(isPresented: $showSmartShelfEditor, editingShelf: editingSmartShelf)
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
        }
        // Supporting Drag & Drop to Import Files seamlessly in initial or running states
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers)
            return true
        }
    }

    // MARK: - Password Lock Screen
    private var passwordLockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Stackroomはロックされています。")
                .font(.headline)

            SecureField("パスワードを入力してください", text: $passwordInput, onCommit: unlockLibrary)
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

    // MARK: - Classic Toolbar (buttons left, filter segments center, search right)
    private var classicToolbarView: some View {
        HStack(spacing: 0) {
            Group {
                toolbarButton(title: "スライドショー", icon: "play.rectangle.fill") {
                    if let item = selectedItem {
                        startSlideshow(item)
                    }
                }
                .disabled(selectedItemID == nil)

                toolbarSeparator

                toolbarButton(title: "ゴミ箱に入れる", icon: "trash.fill") {
                    deleteSelectedItem()
                }
                .disabled(selectedItemID == nil)

                toolbarSeparator

                toolbarButton(title: "Finderで表示", icon: "folder.fill") {
                    if let item = selectedItem {
                        revealInFinder(item)
                    }
                }
                .disabled(selectedItemID == nil)

                toolbarSeparator

                toolbarButton(title: "未読チェック", icon: "checkmark.circle.fill") {
                    selectedItem?.isUnread.toggle()
                }
                .disabled(selectedItemID == nil)

                toolbarButton(title: "表紙を編集", icon: "photo.artframe") {
                    showCoverEditor = true
                }
                .disabled(selectedItemID == nil)

                toolbarSeparator

                toolbarButton(title: isLocked ? "アンロック" : "ロック", icon: isLocked ? "lock.open.fill" : "lock.fill") {
                    if lockEnabled && !passwordValue.isEmpty {
                        isLocked = true
                    }
                }
                .disabled(!lockEnabled || passwordValue.isEmpty)
            }

            Spacer(minLength: 12)

            // Center filter segments (classic Stackroom top-center filters)
            classicFilterSegments

            Spacer(minLength: 12)

            // Search field integrated into the classic bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                TextField("検索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 150)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func toolbarButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(width: 84, height: 52)
            .foregroundColor(.primary.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolbarSeparator: some View {
        Divider()
            .frame(height: 40)
            .padding(.horizontal, 2)
    }

    // MARK: - Classic Filter Segments (未読 / レート / 種類, multi-selectable)
    private var classicFilterSegments: some View {
        HStack(spacing: 12) {
            // 1. Unread Filter: ALL | O
            HStack(spacing: 0) {
                filterOptionButton(title: "ALL", isSelected: unreadFilterSelection == 0) {
                    unreadFilterSelection = 0
                }
                filterSegment(isSelected: unreadFilterSelection == 1) {
                    unreadFilterSelection = 1
                } label: {
                    Circle()
                        .stroke(Color.green, lineWidth: 2.5)
                        .frame(width: 14, height: 14)
                }
            }
            .border(Color.gray.opacity(0.4), width: 1)

            // 2. Type Filter: ALL + 6 colored type icons
            HStack(spacing: 0) {
                filterOptionButton(title: "ALL", isSelected: typeFilterSelection.isEmpty) {
                    typeFilterSelection.removeAll()
                }
                ForEach(0..<BookTypeInfo.count, id: \.self) { idx in
                    filterSegment(isSelected: typeFilterSelection.contains(idx)) {
                        if typeFilterSelection.contains(idx) {
                            typeFilterSelection.remove(idx)
                        } else {
                            typeFilterSelection.insert(idx)
                        }
                    } label: {
                        Image(systemName: BookTypeInfo.systemImage(for: idx))
                            .font(.system(size: 15))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(BookTypeInfo.color(for: idx))
                            .frame(width: 20, height: 18)
                    }
                    .help(typeNames[idx])
                }
            }
            .border(Color.gray.opacity(0.4), width: 1)

            // 3. Rating Filter: ALL | ★ | ★★ | ... (multi-select)
            HStack(spacing: 0) {
                filterOptionButton(title: "ALL", isSelected: ratingFilterSelection.isEmpty) {
                    ratingFilterSelection.removeAll()
                }
                ForEach(1...5, id: \.self) { rate in
                    filterSegment(isSelected: ratingFilterSelection.contains(rate)) {
                        if ratingFilterSelection.contains(rate) {
                            ratingFilterSelection.remove(rate)
                        } else {
                            ratingFilterSelection.insert(rate)
                        }
                    } label: {
                        starRow(count: rate, filled: ratingFilterSelection.contains(rate))
                    }
                }
            }
            .border(Color.gray.opacity(0.4), width: 1)

            // Grid vs List mode switches
            Picker("", selection: $isGridView) {
                Image(systemName: "square.grid.3x3").tag(true)
                Image(systemName: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 72)
            .controlSize(.large)
        }
    }

    private func filterOptionButton(title: String, isSelected: Bool, fontSize: CGFloat = 13, action: @escaping () -> Void) -> some View {
        filterSegment(isSelected: isSelected, action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: isSelected ? .bold : .regular))
        }
    }

    /// A compact star-with-number label used by the rating filter (★1 … ★5).
    private func starRow(count: Int, filled: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundColor(filled ? .blue : .yellow)
            Text("\(count)")
                .font(.system(size: 12, weight: filled ? .bold : .regular))
                .foregroundColor(filled ? .blue : .primary)
        }
    }

    private func filterSegment<Label: View>(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(minWidth: 30, minHeight: 30)
                .background(isSelected ? Color.blue.opacity(0.25) : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .blue : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sidebar Pane
    private var sidebarPane: some View {
        VStack(spacing: 0) {
            List(selection: $sidebarSelection) {
                Section("ライブラリ") {
                    NavigationLink(value: SidebarSelection.allBooks) {
                        Label("すべての本", systemImage: "books.vertical")
                    }
                    NavigationLink(value: SidebarSelection.unreadBooks) {
                        Label("未読の本", systemImage: "book")
                    }
                }

                Section("お気に入り") {
                    let staticShelves = shelves.filter { $0.type == 0 }
                    ForEach(staticShelves) { shelf in
                        NavigationLink(value: SidebarSelection.shelf(shelf.id)) {
                            shelfLabel(shelf)
                        }
                        .contextMenu {
                            Button("削除") {
                                deleteShelf(shelf)
                            }
                        }
                    }
                }

                Section("スマートシェルフ") {
                    let smartShelves = shelves.filter { $0.type == 1 }
                    ForEach(smartShelves) { shelf in
                        NavigationLink(value: SidebarSelection.shelf(shelf.id)) {
                            shelfLabel(shelf)
                        }
                        .contextMenu {
                            Button("編集...") {
                                editingSmartShelf = shelf
                                showSmartShelfEditor = true
                            }
                            Button("削除") {
                                deleteShelf(shelf)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Classic bottom footer controls [+] and [⚙️]
            HStack(spacing: 4) {
                // Add button (+)
                Menu {
                    Button("新規スマートシェルフ...") {
                        editingSmartShelf = nil
                        showSmartShelfEditor = true
                    }
                    Button("新規標準シェルフ...") {
                        createStaticShelf()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .menuStyle(.button)
                .frame(width: 26, height: 20)

                // Settings action button (⚙️)
                Menu {
                    SettingsLink {
                        Text("環境設定...")
                    }
                    Button("ボリューム管理...") {
                        showVolumeManager = true
                    }
                    Button("XMLライブラリのインポート...") {
                        importXMLLibrary()
                    }
                    Button("旧Stackroomサムネイルの移行...") {
                        migrateLegacyThumbnails()
                    }
                    Button("サムネイルの一括修正...") {
                        repairThumbnails()
                    }
                    Button("ファイル名からタイトルを補完...") {
                        repairEmptyTitles()
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .menuStyle(.button)
                .frame(width: 26, height: 20)

                Spacer()
            }
            .padding(6)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    /// Classic colored folder icon per shelf (smart shelves use the gear-folder look).
    private func shelfLabel(_ shelf: Shelf) -> some View {
        HStack(spacing: 6) {
            Image(systemName: shelf.type == 1 ? "gearshape" : "folder.fill")
                .foregroundColor(shelf.type == 1 ? .purple : BookTypeInfo.folderColor(forIcon: shelf.icon))
                .font(.system(size: 12))
            Text(shelf.title)
                .lineLimit(1)
        }
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

            if itemsToDisplay.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(allItems.isEmpty ? "ライブラリは空です。" : "該当する本がありません。")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    if allItems.isEmpty {
                        Text("ZIPや画像フォルダをここにドラッグ＆ドロップして追加できます。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.underPageBackgroundColor))
            } else {
                if isGridView {
                    // Grid view: sort control bar on top
                    gridSortBar
                    Divider()
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 16)], spacing: 16) {
                            ForEach(itemsToDisplay) { item in
                                // Double-tap must be attached BEFORE single-tap,
                                // otherwise the single-tap gesture swallows it.
                                GridItemCardView(item: item, isSelected: selectedItemID == item.id)
                                    .contentShape(Rectangle()) // full-card hit area
                                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                                        selectedItemID = item.id
                                        mainContentHasFocus = true
                                    })
                                    .onTapGesture(count: 2) {
                                        openItem(item)
                                    }
                                    .contextMenu {
                                        itemContextMenu(item)
                                    }
                            }
                        }
                        .padding()
                    }
                    .background(Color(NSColor.underPageBackgroundColor))
                    .focusable()
                    .focused($mainContentHasFocus)
                    .onKeyPress(.return) {
                        if let item = selectedItem {
                            openItem(item)
                            return .handled
                        }
                        return .ignored
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(itemsToDisplay.enumerated(), id: \.element.id) { index, item in
                                    classicListRow(item: item, isSelected: selectedItemID == item.id)
                                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 3)
                                        .background(
                                            selectedItemID == item.id
                                                ? Color(NSColor.selectedContentBackgroundColor)
                                                : (index.isMultiple(of: 2) ? Color(NSColor.alternatingContentBackgroundColors.first ?? .clear) : Color.clear)
                                        )
                                        .contentShape(Rectangle()) // full-row hit area
                                        .id(item.id)
                                        // Single-tap selection fires immediately (simultaneous),
                                        // without waiting to see if it becomes a double-tap.
                                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                                            selectedItemID = item.id
                                            mainContentHasFocus = true
                                        })
                                        .onTapGesture(count: 2) {
                                            openItem(item)
                                        }
                                        .contextMenu {
                                            itemContextMenu(item)
                                        }
                                }
                            }
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .focusable()
                        .focused($mainContentHasFocus)
                        .focusEffectDisabled()
                        .onKeyPress(.downArrow) {
                            moveSelection(by: 1, proxy: proxy)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(by: -1, proxy: proxy)
                            return .handled
                        }
                        .onKeyPress(.return) {
                            if let item = selectedItem {
                                openItem(item)
                                return .handled
                            }
                            return .ignored
                        }
                    }
                }
            }
        }
        // Recompute the (cached) filtered/sorted list only when inputs change,
        // not on every selection/keystroke elsewhere.
        .onAppear { displayItems = computeFilteredItems() }
        .onChange(of: displayToken) { _, _ in
            displayItems = computeFilteredItems()
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
                            .font(.system(size: 11, weight: .semibold))
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
                .foregroundColor(sortKey == col.key ? .primary : .secondary)
                .contextMenu {
                    headerContextMenu
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
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
        let primaryColor: Color = isSelected ? .white : .primary
        let secondaryColor: Color = isSelected ? .white.opacity(0.85) : .secondary
        switch col.key {
        case .unread:
            // Green circle like classic "O"
            Circle()
                .stroke(isSelected ? Color.white : Color.green, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .opacity(item.isUnread ? 1 : 0)
        case .bookType:
            Image(systemName: BookTypeInfo.systemImage(for: item.bookType))
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : BookTypeInfo.color(for: item.bookType))
                .help(typeNames.indices.contains(item.bookType) ? typeNames[item.bookType] : "")
        case .title:
            Text(item.title)
                .font(.system(size: 12))
                .foregroundColor(primaryColor)
                .lineLimit(1)
        case .rating:
            RatingView(rating: .constant(item.rating), interactive: false)
                .font(.system(size: 9))
        case .author:
            Text(item.author)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .genre:
            Text(item.genre)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .relation:
            Text(item.relation)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .keywordA:
            Text(item.keywordA)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .keywordB:
            Text(item.keywordB)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .lastReadDate:
            Text(item.lastReadDate?.formatted(date: .numeric, time: .omitted) ?? "—")
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .addedDate:
            Text(item.addedDate.formatted(date: .numeric, time: .omitted))
                .font(.caption)
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
                        .foregroundColor(.secondary)
                    Text("本棚から本を選択してください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
    }

    private func classicInspectorView(item: Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Large cover image on top
                HStack {
                    Spacer()
                    CoverImageView(item: item)
                        .frame(width: 140, height: 180)
                        .cornerRadius(4)
                        .shadow(radius: 3)
                    Spacer()
                }
                .padding(.top, 8)

                Toggle("未読にする", isOn: Binding(
                    get: { item.isUnread },
                    set: { item.isUnread = $0 }
                ))
                .toggleStyle(.checkbox)
                .padding(.horizontal)

                Divider().padding(.horizontal)

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
                            .foregroundColor(.secondary)
                            .frame(width: 75, alignment: .trailing)
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
                .padding(.horizontal, 4)

                Divider().padding(.horizontal)

                // スタンプ: click to append a registered keyword to the focused field
                StampBarView { stamp in
                    applyStamp(stamp, to: item)
                }
                .padding(.horizontal)

                Divider().padding(.horizontal)

                VStack(alignment: .leading, spacing: 4) {
                    Text("登録日: \(item.addedDate.formatted(date: .numeric, time: .omitted))")
                    if let lastRead = item.lastReadDate {
                        Text("読込日: \(lastRead.formatted(date: .numeric, time: .omitted))")
                    }
                    if item.pages > 0 {
                        Text("ページ数: \(item.pages)p")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func inspectorFieldRow(label: String, field: InspectorField, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 75, alignment: .trailing)

            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
        }
    }

    /// Appends a stamp keyword to the currently focused inspector field
    /// (falls back to キーワードA when nothing is focused).
    private func applyStamp(_ stamp: String, to item: Item) {
        func append(_ value: String) -> String {
            value.isEmpty ? stamp : value + " " + stamp
        }
        switch focusedField ?? .keywordA {
        case .title:    item.title = append(item.title)
        case .author:   item.author = append(item.author)
        case .keywordA: item.keywordA = append(item.keywordA)
        case .keywordB: item.keywordB = append(item.keywordB)
        case .memo:     item.memo = append(item.memo)
        case .genre:    item.genre = append(item.genre)
        case .relation: item.relation = append(item.relation)
        }
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
            let lowerText = searchText.lowercased()
            items = items.filter {
                $0.title.lowercased().contains(lowerText) ||
                $0.author.lowercased().contains(lowerText) ||
                $0.memo.lowercased().contains(lowerText) ||
                $0.keywordA.lowercased().contains(lowerText) ||
                $0.keywordB.lowercased().contains(lowerText)
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

    /// Moves the selection up/down within the displayed items (keyboard nav)
    /// and scrolls the newly selected row into view.
    private func moveSelection(by delta: Int, proxy: ScrollViewProxy?) {
        guard !displayItems.isEmpty else { return }
        let currentIndex = displayItems.firstIndex { $0.id == selectedItemID } ?? -1
        let newIndex = min(max(currentIndex + delta, 0), displayItems.count - 1)
        let id = displayItems[newIndex].id
        selectedItemID = id
        proxy?.scrollTo(id)
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
    private func handleFileDrop(providers: [NSItemProvider]) {
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

                let isZip = url.pathExtension.lowercased() == "zip"
                var isDir: ObjCBool = false
                let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard fileExists && (isZip || isDir.boolValue) else { continue }

                if let id = addDroppedFile(url: url, isZipFile: isZip) {
                    lastAddedID = id
                }
                // Yield so the UI (progress counter) stays responsive
                await Task.yield()
            }

            try? modelContext.save()
            if let lastAddedID {
                selectedItemID = lastAddedID
            }
        }
    }

    /// Registers a single dropped file. Returns the Item id if newly added.
    @discardableResult
    private func addDroppedFile(url: URL, isZipFile: Bool) -> UUID? {
        let (volumePath, volumeName, relativePath) = PathParser.split(url.path)

        // Prevent duplicate (Merge logic). Re-dropping an existing item also
        // repairs its access permission via a fresh security-scoped bookmark.
        let fetchDescriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.relativePath == relativePath })
        if let existing = try? modelContext.fetch(fetchDescriptor).first {
            existing.bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
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
        let parsed = FileNameParser.parse(fileName: url.lastPathComponent)
        let title = parsed.title.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.title

        let newItem = Item(
            id: UUID(),
            volume: volume,
            relativePath: relativePath,
            bookmarkData: itemBookmark,
            title: title,
            author: parsed.author,
            genre: parsed.genre,
            bookType: isZipFile ? 0 : 3,
            fileType: isZipFile ? 2 : 1
        )

        modelContext.insert(newItem)
        return newItem.id
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
        panel.title = "旧Stackroomサムネイルフォルダの選択"
        panel.message = "表紙サムネイルを移行するには、旧Stackroomの「Stackroom Library」フォルダを選択してください。（キャンセルするとサムネイルなしでインポートします）"
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
            var suspects = 0
            var repaired = 0
            var failed = 0

            for (index, item) in items.enumerated() {
                if index % 50 == 0 {
                    processedBooks = index
                }

                let thumbURL = cacheDir.appendingPathComponent("\(item.id.uuidString).jpg")

                // 1. Cheap dimension check (no decode) off the main thread
                let isLandscape = await Task.detached(priority: .utility) {
                    guard let size = CoverSelector.imagePixelSize(at: thumbURL) else { return false }
                    return size.width > size.height
                }.value
                guard isLandscape else { continue }
                suspects += 1

                // 2. Re-extract the cover with the sequence heuristic
                guard let resolved = ItemFileAccess.resolve(item: item) else {
                    failed += 1
                    continue
                }
                let bookURL = resolved.url
                let candidates = await Task.detached(priority: .utility) {
                    CoverSelector.orderedCoverCandidates(from: ItemFileAccess.listPages(at: bookURL))
                }.value

                // Try candidates until one decodes (corrupt image fallback)
                var succeeded = false
                for candidate in candidates {
                    let coverData = await Task.detached(priority: .utility) {
                        ItemFileAccess.loadPageData(bookURL: bookURL, page: candidate)
                    }.value
                    if let coverData,
                       await ThumbnailCache.shared.setCustomCover(forItemID: item.id, imageData: coverData) != nil {
                        succeeded = true
                        break
                    }
                }
                resolved.release()

                if succeeded {
                    repaired += 1
                } else {
                    failed += 1
                }
            }

            isImporting = false
            importMessage = "サムネイルの一括修正が完了しました。\n\n・横長（ゴミ画像疑い）: \(suspects)件\n・修正済み: \(repaired)件\n・修正できず（未接続など）: \(failed)件"
            showImportResult = true
            NotificationCenter.default.post(name: .coverDidChange, object: nil)
        }
    }

    /// Fills empty display titles by parsing the file name with the
    /// 「(ジャンル)[作者名]タイトル.zip」 naming convention. Also fills empty
    /// author/genre fields from the same parse.
    private func repairEmptyTitles() {
        var updated = 0

        for item in allItems {
            guard item.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let fileName = (item.relativePath as NSString).lastPathComponent
            let parsed = FileNameParser.parse(fileName: fileName)

            // Never leave the title empty: fall back to the bare file name
            let newTitle = parsed.title.isEmpty
                ? (fileName as NSString).deletingPathExtension
                : parsed.title
            guard !newTitle.isEmpty else { continue }

            item.title = newTitle
            if item.author.isEmpty { item.author = parsed.author }
            if item.genre.isEmpty { item.genre = parsed.genre }
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
        if selectedItemID == item.id { selectedItemID = nil }
        modelContext.delete(item)
        try? modelContext.save()
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
    }

    private func deleteShelf(_ shelf: Shelf) {
        if case .shelf(let id) = sidebarSelection, id == shelf.id {
            sidebarSelection = .allBooks
        }
        modelContext.delete(shelf)
        try? modelContext.save()
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
            let exts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if exts.contains(ext), idx < appLines.count {
                return helperAppURL(fullPath: appLines[idx], name: appLines[idx])
            }
        }
        return nil
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
        let newShelf = Shelf(title: "新規シェルフ", icon: 0, type: 0)
        modelContext.insert(newShelf)
        try? modelContext.save()
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

// MARK: - Retro horizontal radio grouping support
extension View {
    func horizontalRadioGrouping() -> some View {
        #if os(macOS)
        return self.pickerStyle(.radioGroup)
        #else
        return self
        #endif
    }
}
