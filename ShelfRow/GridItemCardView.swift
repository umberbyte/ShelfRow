//
//  GridItemCardView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI

struct GridItemCardView: View {
    let item: Item
    let isSelected: Bool
    var metrics: DisplayMetrics = .regular

    var body: some View {
        VStack(spacing: metrics.rowSpace(8)) {
            CoverImageView(item: item)
                .frame(width: metrics.size(110), height: metrics.size(145))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                )
                .cornerRadius(4)

            Text(item.title)
                .font(metrics.font(11, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .blue : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: metrics.size(110), height: metrics.size(28), alignment: .top)
        }
    }
}
