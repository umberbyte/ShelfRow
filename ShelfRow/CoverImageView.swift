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
    @State private var showsPreviousCover = false
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(radius: 4, x: 2, y: 2)
                    // Held over from the row before while this one loads: shown so
                    // the pane never goes empty, faded so it is not mistaken for
                    // the selected book's cover.
                    .opacity(showsPreviousCover ? 0.3 : 1)
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
            showsPreviousCover = false
            isLoading = false
            return
        }

        isLoading = false

        let request = ThumbnailRequest(item: item)

        // Blanking the view for a load that resolves in a few milliseconds reads as
        // flicker, and while an arrow key is held it reads as covers not loading at
        // all. Hold the previous cover until either the new one arrives or the wait
        // grows long enough to be worth admitting to.
        showsPreviousCover = image != nil
        let clearPreviousCover = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            image = nil
            showsPreviousCover = false
        }
        defer { clearPreviousCover.cancel() }

        // Thumbnails that are merely on disk still draw right away: reading one is
        // cheap enough to keep up with the cursor, and this path stays off the
        // cache actor so prefetching cannot hold it up.
        if let rendered = await ThumbnailCache.renderedCoverImage(for: request) {
            guard !Task.isCancelled else { return }
            clearPreviousCover.cancel()
            image = rendered
            showsPreviousCover = false
            return
        }
        guard !Task.isCancelled else { return }

        // Everything left has to come out of the archive. Holding an arrow key
        // would queue one extraction per row it passes, and the row the cursor
        // lands on would then wait behind all of them — so start only once the
        // selection has settled here.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        isLoading = true
        let loadedImage = await ThumbnailCache.shared.getCoverImage(for: request)
        guard !Task.isCancelled else { return }

        image = loadedImage
        showsPreviousCover = false
        isLoading = false
    }
}
