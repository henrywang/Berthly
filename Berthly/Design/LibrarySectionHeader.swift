// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// Small tertiary all-caps section header for the library lists (Images "LOCAL"/"PULLED", Volumes
/// "NAMED"/"ANONYMOUS"). `.textCase(nil)` keeps the caller's exact casing and appended count.
struct LibrarySectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(nil)
    }
}
