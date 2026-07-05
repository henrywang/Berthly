import AppKit
import SwiftUI

/// A secure (bulleted) text field that suppresses macOS's password AutoFill affordance — the
/// "Passwords…" suggestion popup a normal `SecureField` shows on focus. There's no public API to
/// opt a secure field out of AutoFill on macOS (iOS has `.newPassword`; macOS has nothing, and
/// `.oneTimeCode` only partially helps), so this overrides AppKit's private
/// `_isPasswordAutofillEnabled` hook. It degrades gracefully: if a future macOS stops consulting
/// that hook, AutoFill simply returns — nothing crashes. Used for the registry token field, which
/// is a PAT typed/pasted from elsewhere, never a credential the Passwords app would know.
struct NoAutoFillSecureField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = AutoFillSuppressingSecureTextField()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // Strip all native chrome — SwiftUI's `.roundedBorder` isn't any AppKit bezel style, so
        // rather than fight to match it, the field is drawn borderless/transparent and the caller
        // wraps it in a SwiftUI rounded border identical to the sheet's other fields.
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private final class AutoFillSuppressingSecureTextField: NSSecureTextField {
    // Same selector AppKit calls internally to decide whether to offer the "Passwords…" AutoFill
    // affordance; returning false opts this field out. Declared via an explicit @objc selector
    // (not a Swift `override`, since the superclass method is private/unexposed).
    @objc(_isPasswordAutofillEnabled)
    func isPasswordAutofillEnabled() -> Bool { false }
}
