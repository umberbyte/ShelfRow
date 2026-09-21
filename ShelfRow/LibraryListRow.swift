import SwiftUI

struct LibraryListColumn: Identifiable {
    let key: ItemSortKey
    let title: String
    let width: CGFloat?
    let alignment: Alignment
    var id: String { key.rawValue }
}

/// SwiftData property observation stays at the row that renders those values.
struct LibraryListRow: View {
    let item: Item
    let isSelected: Bool
    let displayMetrics: DisplayMetrics
    let columns: [LibraryListColumn]
    let typeNames: [String]
    @Environment(\.colorScheme) private var colorScheme
    private var isDarkAppearance: Bool { colorScheme == .dark }
    private var primaryTextColor: Color { Color(nsColor: .labelColor) }
    private var secondaryTextColor: Color { Color(nsColor: .secondaryLabelColor) }

    var body: some View {
        HStack(spacing: displayMetrics.space(8)) {
            ForEach(columns) { col in
                listCell(col, item, isSelected: isSelected)
                    .frame(maxWidth: col.width == nil ? .infinity : nil, alignment: col.alignment)
                    .frame(width: col.width, alignment: col.alignment)
            }
        }
    }

    @ViewBuilder
    private func listCell(_ col: LibraryListColumn, _ item: Item, isSelected: Bool) -> some View {
        // Primary/secondary text turns white on the selection highlight.
        let primaryColor: Color = isSelected ? .white : (isDarkAppearance ? primaryTextColor : .black)
        let secondaryColor: Color = isSelected ? .white.opacity(0.88) : (isDarkAppearance ? secondaryTextColor : .black)
        switch col.key {
        case .unread:
            // Green circle like classic "O"
            Circle()
                .stroke(isSelected ? Color.white : Color.green, lineWidth: 1.5)
                .frame(width: displayMetrics.size(8), height: displayMetrics.size(8))
                .opacity(item.isUnread ? 1 : 0)
        case .bookType:
            Image(systemName: BookTypeInfo.systemImage(for: item.bookType))
                .font(displayMetrics.font(15))
                .foregroundColor(isSelected ? .white : BookTypeInfo.color(for: item.bookType))
                .help(typeNames.indices.contains(item.bookType) ? typeNames[item.bookType] : "")
        case .title:
            Text(item.title)
                .font(displayMetrics.font(14))
                .foregroundColor(primaryColor)
                .lineLimit(1)
        case .rating:
            RatingView(rating: .constant(item.rating), interactive: false)
                .font(displayMetrics.font(11))
        case .author:
            Text(item.author)
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .genre:
            Text(item.genre)
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .relation:
            Text(item.relation)
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .keywordA:
            Text(item.keywordA)
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .keywordB:
            Text(item.keywordB)
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .lastReadDate:
            Text(item.lastReadDate?.formatted(date: .numeric, time: .omitted) ?? "—")
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        case .addedDate:
            Text(item.addedDate.formatted(date: .numeric, time: .omitted))
                .font(displayMetrics.font(13))
                .foregroundColor(secondaryColor)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

}
