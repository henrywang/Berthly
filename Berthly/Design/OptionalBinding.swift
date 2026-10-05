// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

extension Binding {
    /// The `Bool` form that alert, dialog, and sheet modifiers take, for state held as an optional
    /// item: true while it holds a value, and setting it false clears the value.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}
