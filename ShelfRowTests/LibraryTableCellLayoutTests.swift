import AppKit
import Testing
@testable import ShelfRow

struct LibraryTableCellLayoutTests {
    @Test @MainActor
    func textLineIsVerticallyCenteredAtRegularAndCompactSizes() {
        for (rowHeight, fontSize) in [(40.0, 14.0), (30.0, 11.0)] {
            let field = LibraryTextField(frame: NSRect(
                x: 0,
                y: 0,
                width: 240,
                height: rowHeight
            ))
            field.stringValue = "Girls Switch"
            field.font = .systemFont(ofSize: fontSize)

            let drawingRect = field.cell?.drawingRect(forBounds: field.bounds) ?? .zero

            #expect(abs(drawingRect.midY - field.bounds.midY) < 0.01)
            #expect(drawingRect.height < field.bounds.height)
        }
    }

    @Test @MainActor
    func everyColumnReceivesPopulatedRowContent() {
        let source = LibraryItemSnapshot(
            id: UUID(),
            title: "タイトル",
            author: "作者",
            genre: "ジャンル",
            relation: "関連",
            keywordA: "キーワードA",
            keywordB: "キーワードB",
            memo: "メモ",
            rating: 4,
            bookType: 2,
            pages: 192,
            isUnread: true,
            addedDate: Date(timeIntervalSince1970: 1_700_000_000),
            lastReadDate: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let row = LibraryListRowSnapshot(source)
        let expectedText: [ItemSortKey: String] = [
            .title: "タイトル",
            .author: "作者",
            .genre: "ジャンル",
            .relation: "関連",
            .keywordA: "キーワードA",
            .keywordB: "キーワードB",
            .addedDate: source.addedDateText,
            .lastReadDate: source.lastReadDateText,
            .pages: "192"
        ]

        #expect(row.isUnread)
        #expect(row.bookType == 2)
        #expect(row.rating == 4)
        for key in ItemSortKey.allCases {
            if let expected = expectedText[key] {
                #expect(LibraryTableCellContent.text(for: key, item: row) == expected)
            } else {
                #expect([ItemSortKey.unread, .bookType, .rating].contains(key))
            }
        }
    }
}
