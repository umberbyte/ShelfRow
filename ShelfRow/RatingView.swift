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
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .foregroundColor(index <= rating ? .yellow : .secondary.opacity(0.4))
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
    }
}
