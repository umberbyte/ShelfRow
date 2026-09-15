//
//  StampBarView.swift
//  ShelfRow
//
//  Created by Go Sugawara on 2026/09/16.
//

import SwiftUI

/// Classic Stackroom "スタンプ" feature: frequently used keywords registered
/// as clickable chips. Clicking a stamp appends its text to the focused field;
/// the ×  button (edit mode) removes a stamp.
struct StampBarView: View {
    /// Newline-separated stamp list persisted across launches.
    @AppStorage("stampsList") private var stampsList = ""

    @State private var isEditing = false
    @State private var newStampText = ""

    /// Called when the user clicks a stamp.
    let onStamp: (String) -> Void

    private var stamps: [String] {
        stampsList.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("スタンプ:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    isEditing.toggle()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help(isEditing ? "編集を終了" : "スタンプを編集")
            }

            // Stamp chips (wrapping flow)
            WrappingHStack(spacing: 4) {
                ForEach(stamps, id: \.self) { stamp in
                    HStack(spacing: 3) {
                        Button(stamp) {
                            onStamp(stamp)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))

                        if isEditing {
                            Button {
                                removeStamp(stamp)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
                    .foregroundColor(.blue)
                }
            }

            if isEditing {
                HStack(spacing: 4) {
                    TextField("新しいスタンプ", text: $newStampText, onCommit: addStamp)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                    Button {
                        addStamp()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9))
                    }
                    .disabled(newStampText.isEmpty)
                }
            }
        }
    }

    private func addStamp() {
        let text = newStampText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !stamps.contains(text) else { return }
        stampsList = (stamps + [text]).joined(separator: "\n")
        newStampText = ""
    }

    private func removeStamp(_ stamp: String) {
        stampsList = stamps.filter { $0 != stamp }.joined(separator: "\n")
    }
}

/// Minimal wrapping horizontal stack (Layout protocol) for stamp chips.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
