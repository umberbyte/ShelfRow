//
//  RatingView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI

nonisolated enum RatingSelection {
    static func value(afterClicking clicked: Int, current: Int, maximum: Int) -> Int {
        let validMaximum = max(maximum, 0)
        let selected = min(max(clicked, 0), validMaximum)
        return current == selected ? 0 : selected
    }
}

struct RatingView: View {
    @Binding var rating: Int
    var maxRating = 5
    var interactive = true
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxRating, id: \.self) { index in
                let isFilled = index <= rating
                Button {
                    rating = RatingSelection.value(
                        afterClicking: index,
                        current: rating,
                        maximum: maxRating
                    )
                } label: {
                    Image(systemName: isFilled ? "star.fill" : "star")
                        .foregroundColor(isFilled ? .yellow : .secondary.opacity(0.4))
                        .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: 0, y: 1)
                        .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: 0, y: -1)
                        .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: 1, y: 0)
                        .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: -1, y: 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!interactive)
                .accessibilityLabel("評価 \(index)")
                .accessibilityValue(rating == index ? "選択中" : "未選択")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("評価")
        .accessibilityValue("\(rating) / \(maxRating)")
        .accessibilityAdjustableAction { direction in
            guard interactive else { return }
            switch direction {
            case .increment:
                rating = min(rating + 1, maxRating)
            case .decrement:
                rating = max(rating - 1, 0)
            @unknown default:
                break
            }
        }
    }
}
