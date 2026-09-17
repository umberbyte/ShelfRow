//
//  CoverEditorView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI
import ImageIO

extension Notification.Name {
    /// Posted (with the item UUID as object) when a cover thumbnail is replaced.
    static let coverDidChange = Notification.Name("ShelfRow.coverDidChange")
}

/// Faithful recreation of the classic Stackroom "表紙を編集" dialog:
/// browse the images inside the book with a slider and pick one as the cover.
struct CoverEditorView: View {
    let item: Item
    @Binding var isPresented: Bool

    @State private var pages: [BookPage] = []
    @State private var currentIndex = 0
    @State private var previewImage: NSImage? = nil
    @State private var isLoading = true
    @State private var resolvedFile: ResolvedItemFile? = nil
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            Text("表紙の編集")
                .font(.system(size: 13, weight: .bold))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Preview area
            ZStack {
                Color(NSColor.underPageBackgroundColor)

                if let image = previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        .shadow(radius: 4)
                } else if isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 32))
                        Text(pages.isEmpty ? "画像が見つかりません。" : "画像を読み込めませんでした。")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .frame(width: 380, height: 420)

            Divider()

            // Slider to browse pages (classic bottom slider)
            VStack(spacing: 6) {
                if pages.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(currentIndex) },
                            set: { newValue in
                                let idx = Int(newValue.rounded())
                                if idx != currentIndex {
                                    currentIndex = idx
                                    loadPreview()
                                }
                            }
                        ),
                        in: 0...Double(pages.count - 1),
                        step: 1
                    )
                }

                HStack {
                    Button {
                        step(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentIndex <= 0)

                    Button {
                        step(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentIndex >= pages.count - 1)

                    if !pages.isEmpty {
                        Text("\(currentIndex + 1) / \(pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("キャンセル") {
                        isPresented = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("OK") {
                        saveCover()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(previewImage == nil || isSaving)
                }
            }
            .padding(12)
        }
        .frame(width: 380)
        .onAppear(perform: openBook)
        .onDisappear {
            resolvedFile?.release()
            resolvedFile = nil
        }
    }

    private func step(_ delta: Int) {
        let next = currentIndex + delta
        guard pages.indices.contains(next) else { return }
        currentIndex = next
        loadPreview()
    }

    private func openBook() {
        guard let resolved = ItemFileAccess.resolve(item: item) else {
            isLoading = false
            return
        }
        resolvedFile = resolved
        let bookURL = resolved.url

        Task.detached(priority: .userInitiated) {
            let pages = ItemFileAccess.listPages(at: bookURL)
            await MainActor.run {
                self.pages = pages
                self.currentIndex = 0
                if pages.isEmpty {
                    self.isLoading = false
                } else {
                    self.loadPreview()
                }
            }
        }
    }

    private func loadPreview() {
        guard let bookURL = resolvedFile?.url, pages.indices.contains(currentIndex) else { return }
        let page = pages[currentIndex]
        isLoading = true

        Task.detached(priority: .userInitiated) {
            let data = ItemFileAccess.loadPageData(bookURL: bookURL, page: page)
            let image = data.flatMap { Self.previewImage(from: $0) }
            await MainActor.run {
                guard self.pages.indices.contains(self.currentIndex),
                      self.pages[self.currentIndex] == page else { return }
                self.previewImage = image
                self.isLoading = false
            }
        }
    }

    private func saveCover() {
        guard let bookURL = resolvedFile?.url, pages.indices.contains(currentIndex) else { return }
        let page = pages[currentIndex]
        let itemID = item.id
        isSaving = true

        Task {
            let data = await Task.detached(priority: .userInitiated) {
                ItemFileAccess.loadPageData(bookURL: bookURL, page: page)
            }.value

            if let data {
                await ThumbnailCache.shared.setCustomCover(forItemID: itemID, imageData: data)
                NotificationCenter.default.post(name: .coverDidChange, object: itemID)
            }
            isSaving = false
            isPresented = false
        }
    }

    nonisolated private static func previewImage(from data: Data, maxPixelSize: Int = 900) -> NSImage? {
        guard CoverSelector.imageDataLooksComplete(data) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
