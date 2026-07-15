// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

extension Color {
    // Brand accent — primary buttons, selected state, progress bars
    static let berthlyAccent  = Color(hex: "2563EB")

    // Semantic status — shapes carry the meaning, color reinforces it
    static let statusRunning  = Color(hex: "16A34A")
    static let statusError    = Color(hex: "DC2626")
    static let statusPaused   = Color(hex: "D97706")

    // Code / terminal surfaces
    static let codeBackground = Color(hex: "0F1117")
    static let codePrompt     = Color(hex: "4ADE80")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red:   Double((int >> 16) & 0xFF) / 255,
            green: Double((int >>  8) & 0xFF) / 255,
            blue:  Double( int        & 0xFF) / 255
        )
    }
}

extension ContainerStatus {
    var color: Color {
        switch self {
        case .running: .statusRunning
        case .stopped: Color(NSColor.tertiaryLabelColor)
        case .error:   .statusError
        case .paused:  .statusPaused
        }
    }

    // Shape-coded indicator so colorblind users can distinguish states
    var systemImage: String {
        switch self {
        case .running: "circle.fill"
        case .stopped: "circle"
        case .error:   "triangle.fill"
        case .paused:  "pause.fill"
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .error:   "Error"
        case .paused:  "Paused"
        }
    }
}
