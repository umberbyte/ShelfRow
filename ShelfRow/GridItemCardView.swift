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
    
    var body: some View {
        VStack(spacing: 8) {
            CoverImageView(item: item)
                .frame(width: 110, height: 145)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                )
                .cornerRadius(4)
            
            Text(item.title)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .blue : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 110, height: 28, alignment: .top)
        }
    }
}
