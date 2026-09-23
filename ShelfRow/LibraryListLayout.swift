import Foundation

/// Shared geometry for the list header and its data rows.
///
/// Keeping the effective content inset identical matters because the title
/// column is flexible. Even a small width difference makes every column after
/// the title appear shifted.
enum LibraryListLayout {
    static func columnSpacing(_ metrics: DisplayMetrics) -> CGFloat {
        metrics.space(8)
    }

    static func contentInset(_ metrics: DisplayMetrics) -> CGFloat {
        metrics.space(10)
    }

    static func rowBackgroundInset(_ metrics: DisplayMetrics) -> CGFloat {
        metrics.space(6)
    }

    static func rowInnerInset(_ metrics: DisplayMetrics) -> CGFloat {
        max(0, contentInset(metrics) - rowBackgroundInset(metrics))
    }
}
