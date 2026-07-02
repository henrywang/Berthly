import AppKit
import SwiftUI

/// Bridges to a real AppKit `NSPopover` instead of SwiftUI's `.popover()` modifier.
///
/// SwiftUI's `.popover()` attached to a `ToolbarItemGroup` button turned out unreliable in this
/// app: on repeated programmatic opens it sometimes didn't render at all, and on the runs where
/// it did render, its content wasn't exposed through the Accessibility API — confirmed via both
/// System Events and XCUITest, neither could find the buttons inside it even while they were
/// visibly on screen. Since that's the same API VoiceOver relies on, that's a real accessibility
/// gap, not just a test-automation inconvenience. A real `NSPopover` hosting an
/// `NSHostingController` is the native mechanism and doesn't go through whatever SwiftUI's
/// toolbar-popover integration is doing.
struct PopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    var preferredEdge: NSRectEdge = .maxY
    @ViewBuilder let content: () -> PopoverContent

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        if isPresented {
            context.coordinator.show(from: nsView, content: content())
        } else {
            context.coordinator.close()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: PopoverAnchor
        private var popover: NSPopover?

        init(_ parent: PopoverAnchor) {
            self.parent = parent
        }

        func show(from view: NSView, content: PopoverContent) {
            guard popover == nil else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: content)
            self.popover = popover
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: parent.preferredEdge)
        }

        func close() {
            guard let popover else { return }
            self.popover = nil
            popover.close()
        }

        func popoverWillClose(_ notification: Notification) {
            popover = nil
            if parent.isPresented {
                parent.isPresented = false
            }
        }
    }
}
