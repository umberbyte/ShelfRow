import SwiftUI

/// Keyboard focus belongs to a stable container, outside the scrolling content.
/// Scroll requests are one-way: viewport feedback must not replace the requested
/// selection while a held arrow key is moving through a lazy layout.
struct LibraryKeyboardScrollView<Content: View>: View {
    let targetID: UUID?
    let focus: FocusState<Bool>.Binding
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    content()
                }
                .onChange(of: targetID) { _, id in
                    guard let id else { return }
                    // No anchor means the smallest scroll needed to reveal it.
                    // Do not animate a stream of key-repeat scroll requests.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(id)
                    }
                }
            }
            .focusable(interactions: .edit)
            .focused(focus)
            .focusEffectDisabled()
        }
    }
}

enum LibraryKeyboardNavigation: Sendable {
    /// A nil result means the key was handled without changing the selection.
    nonisolated static func destination(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0, delta != 0 else { return nil }
        guard let index, (0..<count).contains(index) else { return 0 }
        let step = min(max(delta, -count), count)
        let next = step > 0 ? index + min(step, count - 1 - index) : index + max(step, -index)
        return next == index ? nil : next
    }
}
