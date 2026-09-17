//
//  RatingView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI

struct RatingView: View {
    @Binding var rating: Int
    var maxRating = 5
    var interactive = true
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxRating, id: \.self) { index in
                let isFilled = index <= rating
                Image(systemName: isFilled ? "star.fill" : "star")
                    .foregroundColor(isFilled ? .yellow : .secondary.opacity(0.4))
                    .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: 0, y: 1)
                    .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: 0, y: -1)
                    .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: 1, y: 0)
                    .shadow(color: isFilled ? .black.opacity(0.85) : .clear, radius: 0, x: -1, y: 0)
                    .onTapGesture {
                        if interactive {
                            if rating == index {
                                rating = 0 // Toggle off if clicked same rating
                            } else {
                                rating = index
                            }
                        }
                    }
                    .disabled(!interactive)
            }
        }
        .accessibilityElement(children: .ignore)
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
