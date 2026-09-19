//
//  PaneMetrics.swift
//  ShelfRow
//

import SwiftUI

/// Sizes for the side panes, so a narrow display can be given a smaller set
/// without every view growing its own opinion about what "compact" means.
///
/// Spacing shrinks further than the elements do. At three quarters the type and
/// icons are still comfortable to read, and what actually costs the height on a
/// short screen is the air between rows — so that is cut harder.
struct PaneMetrics: Equatable {
    static let elementScale: CGFloat = 0.75
    static let spacingScale: CGFloat = 0.55

    let isCompact: Bool

    static let regular = PaneMetrics(isCompact: false)
    static let compact = PaneMetrics(isCompact: true)

    init(isCompact: Bool) {
        self.isCompact = isCompact
    }

    /// Anything measured in its own right: icons, control heights, label columns.
    func size(_ points: CGFloat) -> CGFloat {
        isCompact ? (points * Self.elementScale).rounded() : points
    }

    /// Gaps, padding and insets.
    func space(_ points: CGFloat) -> CGFloat {
        isCompact ? (points * Self.spacingScale).rounded() : points
    }

    /// Kept above nine points, below which the labels stop being readable at
    /// any useful distance.
    func font(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: isCompact ? max(9, (points * Self.elementScale).rounded()) : points, weight: weight)
    }

    /// Pane widths, which have to come down with the contents or the saved
    /// splitter positions leave the smaller layout floating in empty space.
    func width(min: CGFloat, ideal: CGFloat, max: CGFloat) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        (size(min), size(ideal), size(max))
    }
}
