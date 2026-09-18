//
//  CoverImageView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI

struct CoverImageView: View {
    let item: Item
    @State private var image: NSImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 4, x: 2, y: 2)
            } else if isLoading {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.1))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                    )
            } else {
                // Fallback book placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                            Text(item.title)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 6)
                        }
                    )
                    .shadow(radius: 2)
            }
        }
        .task(id: item.id) {
            await loadImage()
        }
        // Reload when the cover is replaced (表紙を編集) or after bulk
        // thumbnail migration (object == nil means "all covers changed").
        .onReceive(NotificationCenter.default.publisher(for: .coverDidChange)) { notification in
            if (notification.object as? UUID) == item.id {
                Task {
                    await ThumbnailCache.shared.invalidateFailure(forItemID: item.id)
                    await loadImage()
                }
            } else if notification.object == nil, image == nil {
                Task {
                    await ThumbnailCache.shared.invalidateFailure(forItemID: nil)
                    await loadImage()
                }
            }
        }
    }
    
    @MainActor
    private func loadImage() async {
        // Already decoded: draw it in this frame rather than blanking the view
        // for an actor hop that would only hand back the same image.
        if let cached = ThumbnailCache.cachedImage(forItemID: item.id) {
            image = cached
            isLoading = false
            return
        }

        image = nil
        isLoading = true

        let loadedImage = await ThumbnailCache.shared.getCoverImage(for: ThumbnailRequest(item: item))
        guard !Task.isCancelled else { return }

        image = loadedImage
        isLoading = false
    }
}
