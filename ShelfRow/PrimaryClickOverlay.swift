import AppKit
import SwiftUI

/// Reliable macOS single/double-click handling used by library rows and cards.
/// Applying it per noninteractive list cell leaves embedded controls, such as
/// the rating buttons, free to receive their own pointer events.
struct PrimaryClickOverlay: NSViewRepresentable {
    let onPrimaryClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onPrimaryClick = onPrimaryClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onPrimaryClick = onPrimaryClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class ClickView: NSView {
        var onPrimaryClick: ((NSEvent.ModifierFlags) -> Void)?
        var onDoubleClick: (() -> Void)?

        override var acceptsFirstResponder: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = window?.currentEvent else {
                return super.hitTest(point)
            }
            switch event.type {
            case .leftMouseDown:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func mouseDown(with event: NSEvent) {
            onPrimaryClick?(event.modifierFlags)
            if event.clickCount >= 2 {
                onDoubleClick?()
            }
        }
    }
}
