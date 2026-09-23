import AppKit
import SwiftUI

enum LibraryTableAction {
    case startSlideshow(UUID)
    case open(UUID)
    case delete(UUID)
    case trash(UUID)
    case setRating(UUID, Int)
    case setBookType(UUID, Int)
    case toggleUnread(UUID)
    case revealInFinder(UUID)
    case moveFile(UUID)
    case renameFile(UUID)
    case editCover(UUID)
    case reassignFile(UUID)
    case sort(ItemSortKey)
    case toggleColumn(ItemSortKey)
}

/// A narrow AppKit bridge for the one part of the screen where view reuse and
/// native selection materially affect performance. SwiftUI remains the source
/// of truth for rows, selection, sorting, and persisted column preferences.
struct LibraryTableView: NSViewRepresentable {
    let rows: [LibraryListRowSnapshot]
    let rowsGeneration: UInt64
    let columns: [LibraryListColumn]
    let selectedIDs: Set<UUID>
    let sortKey: ItemSortKey
    let sortAscending: Bool
    let visibleColumnKeys: Set<String>
    let typeNames: [String]
    let displayMetrics: DisplayMetrics
    let onSelectionChange: (Set<UUID>, UUID?) -> Void
    let onAction: (LibraryTableAction) -> Void
    let onColumnOrderChange: ([ItemSortKey]) -> Void
    let onColumnWidthChange: (ItemSortKey, Double) -> Void
    let onDeleteSelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> LibraryTableHostView {
        let host = LibraryTableHostView()
        let table = host.tableView
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelectedRow)
        table.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(for: row)
        }
        table.deleteAction = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onDeleteSelection()
        }
        host.layoutHandler = { [weak coordinator = context.coordinator] availableWidth in
            coordinator?.fitFlexibleColumn(to: availableWidth)
        }
        context.coordinator.attach(tableView: table, hostView: host)
        context.coordinator.apply(parent: self, forceReload: true)
        return host
    }

    func updateNSView(_ nsView: LibraryTableHostView, context: Context) {
        context.coordinator.apply(parent: self, forceReload: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: LibraryTableView
        private weak var tableView: LibraryFastTableView?
        private weak var hostView: LibraryTableHostView?
        private var displayedRows: [LibraryListRowSnapshot] = []
        private var displayedGeneration: UInt64 = 0
        private var appliedColumns: [ColumnState] = []
        private var previousSelection = IndexSet()
        private var appliedColumnWidths: [ItemSortKey: CGFloat] = [:]
        private var columnResizeTask: Task<Void, Never>?
        private var isApplyingColumns = false
        private var isApplyingSelection = false

        init(parent: LibraryTableView) {
            self.parent = parent
        }

        func attach(tableView: LibraryFastTableView, hostView: LibraryTableHostView) {
            self.tableView = tableView
            self.hostView = hostView
        }

        func apply(parent: LibraryTableView, forceReload: Bool) {
            self.parent = parent
            guard let tableView else { return }

            let columnStates = parent.columns.map {
                ColumnState(key: $0.key, title: $0.title, width: $0.width)
            }
            if forceReload || columnStates != appliedColumns {
                applyColumns(columnStates, to: tableView)
            }

            if forceReload || displayedGeneration != parent.rowsGeneration {
                replaceRows(parent.rows, generation: parent.rowsGeneration, in: tableView)
            }

            applySelection(to: tableView)
            configureTableAppearance(tableView)
            tableView.headerView?.menu = headerMenu()
            hostView?.needsLayout = true
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayedRows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard displayedRows.indices.contains(row),
                  let tableColumn,
                  let key = ItemSortKey(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let item = displayedRows[row]
            let selected = tableView.selectedRowIndexes.contains(row)

            switch key {
            case .unread:
                let view = reusableUnreadView(in: tableView, column: tableColumn)
                view.isUnread = item.isUnread
                view.isRowSelected = selected
                return view
            case .bookType:
                let view = reusableImageView(in: tableView, column: tableColumn)
                let symbol = BookTypeInfo.systemImage(for: item.bookType)
                view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                view.imageScaling = .scaleProportionallyDown
                view.contentTintColor = selected
                    ? .alternateSelectedControlTextColor
                    : NSColor(BookTypeInfo.color(for: item.bookType))
                view.toolTip = parent.typeNames.indices.contains(item.bookType)
                    ? parent.typeNames[item.bookType]
                    : nil
                return view
            case .rating:
                let view = reusableRatingView(in: tableView, column: tableColumn)
                view.itemID = item.id
                view.rating = item.rating
                view.isRowSelected = selected
                view.onChange = { [weak self] id, rating in
                    self?.parent.onAction(.setRating(id, rating))
                }
                return view
            default:
                let view = reusableTextView(in: tableView, column: tableColumn)
                view.stringValue = LibraryTableCellContent.text(for: key, item: item)
                view.alignment = key == .pages ? .right : .left
                view.font = font(for: key)
                view.textColor = selected ? .alternateSelectedControlTextColor : textColor(for: key)
                view.toolTip = view.stringValue
                return view
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, !isApplyingSelection else { return }
            if tableView.selectedRow >= 0 {
                tableView.scrollRowToVisible(tableView.selectedRow)
            }
            let changed = previousSelection.symmetricDifference(tableView.selectedRowIndexes)
            previousSelection = tableView.selectedRowIndexes
            reloadRows(changed, in: tableView)

            let ids = Set(tableView.selectedRowIndexes.compactMap { index in
                displayedRows.indices.contains(index) ? displayedRows[index].id : nil
            })
            let primaryRow = tableView.selectedRow
            let primaryID = displayedRows.indices.contains(primaryRow)
                ? displayedRows[primaryRow].id
                : ids.first
            parent.onSelectionChange(ids, primaryID)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let key = ItemSortKey(rawValue: tableColumn.identifier.rawValue) else { return }
            parent.onAction(.sort(key))
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tableView, !isApplyingColumns else { return }
            let order = tableView.tableColumns.compactMap {
                ItemSortKey(rawValue: $0.identifier.rawValue)
            }
            parent.onColumnOrderChange(order)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView, !isApplyingColumns else { return }
            for column in tableView.tableColumns {
                guard let key = ItemSortKey(rawValue: column.identifier.rawValue),
                      LibraryColumnWidth.isResizable(key),
                      let previous = appliedColumnWidths[key],
                      abs(column.width - previous) > 0.5 else { continue }
                appliedColumnWidths[key] = column.width
                let logicalWidth = Double(column.width)
                    / Double(parent.displayMetrics.isCompact ? DisplayMetrics.elementScale : 1)
                columnResizeTask?.cancel()
                columnResizeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, let self else { return }
                    self.parent.onColumnWidthChange(key, logicalWidth)
                }
            }
        }

        @objc func openSelectedRow() {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard displayedRows.indices.contains(row) else { return }
            parent.onAction(.open(displayedRows[row].id))
        }

        func contextMenu(for row: Int) -> NSMenu? {
            guard displayedRows.indices.contains(row) else { return nil }
            let item = displayedRows[row]
            let menu = NSMenu()
            menu.addItem(commandItem("スライドショー", .startSlideshow(item.id)))
            menu.addItem(commandItem("このヘルパーで開く", .open(item.id)))
            menu.addItem(.separator())
            menu.addItem(commandItem("削除", .delete(item.id)))
            menu.addItem(commandItem("ゴミ箱に入れる...", .trash(item.id)))

            let ratingItem = NSMenuItem(title: "レート", action: nil, keyEquivalent: "")
            let ratingMenu = NSMenu()
            ratingMenu.addItem(commandItem("なし", .setRating(item.id, 0)))
            for rating in 1...5 {
                ratingMenu.addItem(commandItem(
                    String(repeating: "★", count: rating),
                    .setRating(item.id, rating)
                ))
            }
            ratingItem.submenu = ratingMenu
            menu.addItem(ratingItem)

            let typeItem = NSMenuItem(title: "種類", action: nil, keyEquivalent: "")
            let typeMenu = NSMenu()
            for index in 0..<BookTypeInfo.count {
                let title = parent.typeNames.indices.contains(index) ? parent.typeNames[index] : "種類 \(index + 1)"
                typeMenu.addItem(commandItem(title, .setBookType(item.id, index)))
            }
            typeItem.submenu = typeMenu
            menu.addItem(typeItem)
            menu.addItem(commandItem("未読チェック", .toggleUnread(item.id)))
            menu.addItem(.separator())
            menu.addItem(commandItem("Finderで表示", .revealInFinder(item.id)))
            menu.addItem(commandItem("ファイルを移動...", .moveFile(item.id)))
            menu.addItem(commandItem("ファイルをリネーム...", .renameFile(item.id)))
            menu.addItem(commandItem("表紙を編集...", .editCover(item.id)))
            menu.addItem(commandItem("ファイルを再指定...", .reassignFile(item.id)))

            let sortItem = NSMenuItem(title: "並び替え", action: nil, keyEquivalent: "")
            sortItem.submenu = sortMenu()
            menu.addItem(.separator())
            menu.addItem(sortItem)
            return menu
        }

        func fitFlexibleColumn(to availableWidth: CGFloat) {
            guard let tableView,
                  let flexibleState = appliedColumns.first(where: { $0.width == nil }),
                  let flexibleColumn = tableView.tableColumns.first(where: {
                      $0.identifier.rawValue == flexibleState.key.rawValue
                  }) else { return }
            let fixed = tableView.tableColumns
                .filter { $0 !== flexibleColumn }
                .reduce(CGFloat.zero) { $0 + $1.width }
            let spacing = tableView.intercellSpacing.width * CGFloat(max(0, tableView.numberOfColumns - 1))
            let target = max(flexibleColumn.minWidth, availableWidth - fixed - spacing)
            guard abs(flexibleColumn.width - target) > 0.5 else { return }
            isApplyingColumns = true
            flexibleColumn.width = target
            appliedColumnWidths[flexibleState.key] = target
            isApplyingColumns = false
        }

        private func replaceRows(
            _ rows: [LibraryListRowSnapshot],
            generation: UInt64,
            in tableView: NSTableView
        ) {
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            let anchorIndex = visibleRange.location != NSNotFound ? visibleRange.location : -1
            let anchorID = displayedRows.indices.contains(anchorIndex) ? displayedRows[anchorIndex].id : nil
            let anchorOffset = anchorIndex >= 0
                ? tableView.visibleRect.minY - tableView.rect(ofRow: anchorIndex).minY
                : 0

            displayedRows = rows
            displayedGeneration = generation
            tableView.reloadData()

            if let anchorID, let newIndex = rows.firstIndex(where: { $0.id == anchorID }) {
                let targetY = tableView.rect(ofRow: newIndex).minY + anchorOffset
                if let scrollView = tableView.enclosingScrollView {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }

        private func applySelection(to tableView: NSTableView) {
            var desired = IndexSet()
            for (index, row) in displayedRows.enumerated() where parent.selectedIDs.contains(row.id) {
                desired.insert(index)
            }
            guard desired != tableView.selectedRowIndexes else { return }
            let changed = tableView.selectedRowIndexes.symmetricDifference(desired)
            isApplyingSelection = true
            tableView.selectRowIndexes(desired, byExtendingSelection: false)
            isApplyingSelection = false
            previousSelection = desired
            reloadRows(changed, in: tableView)
        }

        private func applyColumns(_ states: [ColumnState], to tableView: NSTableView) {
            isApplyingColumns = true
            defer { isApplyingColumns = false }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }
            let scale = parent.displayMetrics.isCompact ? DisplayMetrics.elementScale : 1
            for state in states {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(state.key.rawValue))
                column.title = state.title
                column.headerCell.alignment = .center
                column.minWidth = CGFloat(LibraryColumnWidth.minimum(for: state.key)) * scale
                column.maxWidth = CGFloat(LibraryColumnWidth.maximum) * scale
                if let width = state.width {
                    column.width = width
                } else {
                    column.width = max(column.minWidth, 240 * scale)
                }
                column.resizingMask = LibraryColumnWidth.isResizable(state.key)
                    ? [.userResizingMask]
                    : []
                tableView.addTableColumn(column)
                appliedColumnWidths[state.key] = column.width
            }
            appliedColumns = states
        }

        private func configureTableAppearance(_ tableView: NSTableView) {
            tableView.rowHeight = parent.displayMetrics.size(30)
                + 2 * parent.displayMetrics.rowSpace(5)
                + 2 * parent.displayMetrics.rowSpace(1)
            tableView.intercellSpacing = NSSize(
                width: LibraryListLayout.columnSpacing(parent.displayMetrics),
                height: 0
            )
            tableView.backgroundColor = .clear
            tableView.gridColor = .separatorColor
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.setAccessibilityIdentifier("libraryTable")
            tableView.setAccessibilityLabel("ライブラリ")
        }

        private func reloadRows(_ rows: IndexSet, in tableView: NSTableView) {
            guard !rows.isEmpty, tableView.numberOfColumns > 0 else { return }
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }

        private func reusableTextView(in tableView: NSTableView, column: NSTableColumn) -> LibraryTextField {
            let identifier = NSUserInterfaceItemIdentifier("text.\(column.identifier.rawValue)")
            if let view = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryTextField {
                return view
            }
            let view = LibraryTextField()
            view.identifier = identifier
            return view
        }

        private func reusableImageView(in tableView: NSTableView, column: NSTableColumn) -> NSImageView {
            let identifier = NSUserInterfaceItemIdentifier("image.\(column.identifier.rawValue)")
            if let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSImageView {
                return view
            }
            let view = NSImageView()
            view.identifier = identifier
            view.imageAlignment = .alignCenter
            return view
        }

        private func reusableUnreadView(in tableView: NSTableView, column: NSTableColumn) -> LibraryUnreadCellView {
            let identifier = NSUserInterfaceItemIdentifier("unread.\(column.identifier.rawValue)")
            if let view = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryUnreadCellView {
                return view
            }
            let view = LibraryUnreadCellView()
            view.identifier = identifier
            return view
        }

        private func reusableRatingView(in tableView: NSTableView, column: NSTableColumn) -> LibraryRatingCellView {
            let identifier = NSUserInterfaceItemIdentifier("rating.\(column.identifier.rawValue)")
            if let view = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryRatingCellView {
                return view
            }
            let view = LibraryRatingCellView()
            view.identifier = identifier
            return view
        }

        private func font(for key: ItemSortKey) -> NSFont {
            let points: CGFloat = key == .title ? 14 : 13
            let size = parent.displayMetrics.isCompact
                ? max(9, (points * DisplayMetrics.elementScale).rounded())
                : points
            return .systemFont(ofSize: size)
        }

        private func textColor(for key: ItemSortKey) -> NSColor {
            key == .title ? .labelColor : .secondaryLabelColor
        }

        private func headerMenu() -> NSMenu {
            let menu = NSMenu()
            let sortItem = NSMenuItem(title: "並び替え", action: nil, keyEquivalent: "")
            sortItem.submenu = sortMenu()
            menu.addItem(sortItem)
            menu.addItem(.separator())
            for key in LibraryColumnOrder.canonical where key != .title {
                let item = commandItem(key.label, .toggleColumn(key))
                item.state = parent.visibleColumnKeys.contains(key.rawValue) ? .on : .off
                menu.addItem(item)
            }
            return menu
        }

        private func sortMenu() -> NSMenu {
            let menu = NSMenu()
            for key in ItemSortKey.allCases {
                let item = commandItem(key.label, .sort(key))
                if parent.sortKey == key {
                    item.state = .on
                    item.title += parent.sortAscending ? "  ↑" : "  ↓"
                }
                menu.addItem(item)
            }
            return menu
        }

        private func commandItem(_ title: String, _ command: LibraryTableAction) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(performMenuCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = LibraryTableCommandBox(command)
            return item
        }

        @objc private func performMenuCommand(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? LibraryTableCommandBox else { return }
            parent.onAction(box.command)
        }
    }
}

private struct ColumnState: Equatable {
    let key: ItemSortKey
    let title: String
    let width: CGFloat?
}

@MainActor
private final class LibraryTableCommandBox: NSObject {
    let command: LibraryTableAction
    init(_ command: LibraryTableAction) {
        self.command = command
    }
}

nonisolated enum LibraryTableCellContent {
    static func text(for key: ItemSortKey, item: LibraryListRowSnapshot) -> String {
        switch key {
        case .title: item.title
        case .author: item.author
        case .genre: item.genre
        case .relation: item.relation
        case .keywordA: item.keywordA
        case .keywordB: item.keywordB
        case .addedDate: item.addedDateText
        case .lastReadDate: item.lastReadDateText
        case .pages: String(item.pages)
        case .unread, .bookType, .rating: ""
        }
    }
}

/// Keeps NSTextField as the table's direct reusable cell while moving only its
/// text drawing rectangle to the vertical center of the row.
@MainActor
final class LibraryTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = LibraryVerticallyCenteredTextFieldCell(textCell: "")
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class LibraryVerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = min(drawingRect.height, ceil(cellSize(forBounds: rect).height))
        drawingRect.origin.y += (drawingRect.height - textHeight) / 2
        drawingRect.size.height = textHeight
        return drawingRect
    }
}

@MainActor
final class LibraryTableHostView: NSView {
    let scrollView = NSScrollView()
    let tableView = LibraryFastTableView()
    var layoutHandler: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        tableView.autoresizingMask = [.width]
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutHandler?(scrollView.contentSize.width)
    }
}

@MainActor
final class LibraryFastTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    var deleteAction: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        let navigationModifiers = event.modifierFlags.intersection([.command, .option, .shift])
        if navigationModifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            let delta = event.keyCode == 125 ? 1 : -1
            let startingRow = selectedRow >= 0 ? selectedRow : (delta > 0 ? -1 : numberOfRows)
            let targetRow = min(max(0, startingRow + delta), max(0, numberOfRows - 1))
            guard numberOfRows > 0 else { return }
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            scrollRowToVisible(targetRow)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let action = doubleAction, let target {
                NSApp.sendAction(action, to: target, from: self)
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteAction?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class LibraryUnreadCellView: NSView {
    var isUnread = false { didSet { needsDisplay = true } }
    var isRowSelected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isUnread else { return }
        let diameter: CGFloat = 8
        let rect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        (isRowSelected ? NSColor.alternateSelectedControlTextColor : .systemGreen).setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 1.5
        path.stroke()
    }
}

@MainActor
private final class LibraryRatingCellView: NSControl {
    var itemID = UUID()
    var rating = 0 { didSet { needsDisplay = true } }
    var isRowSelected = false { didSet { needsDisplay = true } }
    var onChange: ((UUID, Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let segment = max(1, bounds.width / 5)
        let symbolSize = min(CGFloat(13), max(CGFloat(9), bounds.height - 8))
        let font = NSFont.systemFont(ofSize: symbolSize)
        for index in 1...5 {
            let x = segment * CGFloat(index - 1) + (segment - symbolSize) / 2
            let y = (bounds.height - symbolSize) / 2
            let tint: NSColor = index <= rating
                ? .systemYellow
                : (isRowSelected ? .alternateSelectedControlTextColor.withAlphaComponent(0.55) : .tertiaryLabelColor)
            let glyph = index <= rating ? "★" : "☆"
            (glyph as NSString).draw(
                at: NSPoint(x: x, y: y),
                withAttributes: [.font: font, .foregroundColor: tint]
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let tableView = enclosingScrollView?.documentView as? NSTableView {
            let row = tableView.row(for: self)
            if row >= 0, !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = min(5, max(1, Int(point.x / max(1, bounds.width / 5)) + 1))
        rating = RatingSelection.value(afterClicking: clicked, current: rating, maximum: 5)
        onChange?(itemID, rating)
    }

    override func accessibilityLabel() -> String? { "評価" }
    override func accessibilityValue() -> Any? { "\(rating) / 5" }
}
