// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Human-readable byte size (B/KB/MB/GB), picking the largest unit that keeps the number ≥ 1.
/// Shared by the image list and detail views, which both display raw byte counts.
func formatSize(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    if mb >= 1    { return String(format: "%.0f MB", mb) }
    let kb = Double(bytes) / 1024
    if kb >= 1    { return String(format: "%.0f KB", kb) }
    return "\(bytes) B"
}

/// Human-readable size from a megabyte count (volumes report usage in MB, not bytes): MB below
/// 1 GB, GB above. Shared by the volume list and detail views.
func formatVolumeMB(_ mb: Int) -> String {
    mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
}
