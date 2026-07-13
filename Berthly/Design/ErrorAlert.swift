import SwiftUI

extension View {
    /// Standard one-button error alert bound to an optional message string: present it by setting
    /// the string, dismiss clears it. Replaces the hand-rolled `.alert("Error", isPresented:
    /// Binding(get:set:))` block that was copy-pasted across every list, detail, and sheet view.
    func errorAlert(_ message: Binding<String?>, title: LocalizedStringKey = "Error") -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("OK") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
