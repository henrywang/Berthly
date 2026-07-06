// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit

/// Replaces the clipboard contents with `text` — the one-liner every "Copy …" context-menu
/// item and copy button shares.
@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
