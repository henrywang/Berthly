// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// Spotlight-style command palette (⌘K). A top-center overlay — not a sheet, which centers — with
/// a focused search field and a ranked result list driven entirely by the pure matcher in
/// `Core/CommandPalette.swift`. Keyboard-first: ↑/↓ move the selection, ⏎ runs it, ⎋ dismisses.
///
/// The command set and dispatch both live in `MainWindowView`; this view is presentation only.
struct CommandPaletteView: View {
    let commands: [PaletteCommand]
    let onRun: (PaletteAction) -> Void
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    /// Hover may only steal the selection after the pointer has actually moved. Without this,
    /// a palette that opens under a stationary mouse fires `.active` for whatever row happens
    /// to be under the pointer — preselecting a random mid-list command (and scrolling to it),
    /// so a reflexive ⌘K-then-⏎ could run something like "Restart …" the user never chose.
    @State private var hoverArmed = false
    @State private var lastHoverLocation: CGPoint?
    /// True while the latest selection change came from hover — those must not auto-scroll
    /// (the list would shift under the pointer); only ↑/↓ moves recenter the selection.
    @State private var selectionFollowsHover = false

    private var results: [PaletteCommand] {
        rankedPaletteCommands(commands, query: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — click anywhere outside the card to dismiss.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            palette
                .frame(width: 560)
                .padding(.top, 96)
        }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        // Fallback for when the search field has lost focus (the field's own `.onKeyPress`
        // only sees ⎋ while focused) — cancelOperation bubbles up here from any descendant.
        .onExitCommand { isPresented = false }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityIdentifier("commandPaletteSearchField")
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.return) { runSelected(); return .handled }
                .onKeyPress(.escape) { isPresented = false; return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onChange(of: query) { _, _ in
            selectionFollowsHover = false
            selectedIndex = 0
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            Text("No matching commands")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            PaletteRow(command: command, isSelected: index == selectedIndex)
                                .id(command.id)
                                .contentShape(Rectangle())
                                .onTapGesture { run(command) }
                                .onContinuousHover(coordinateSpace: .global) { phase in
                                    guard case .active(let location) = phase else { return }
                                    // Global (window) coordinates so scrolling rows under a
                                    // stationary pointer doesn't count as a move either.
                                    if let last = lastHoverLocation, last != location {
                                        hoverArmed = true
                                    }
                                    lastHoverLocation = location
                                    if hoverArmed {
                                        selectionFollowsHover = true
                                        selectedIndex = index
                                    }
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, index in
                    guard !selectionFollowsHover, results.indices.contains(index) else { return }
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(results[index].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectionFollowsHover = false
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func runSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        run(results[selectedIndex])
    }

    private func run(_ command: PaletteCommand) {
        isPresented = false
        onRun(command.action)
    }
}

/// One result row: icon, title, and (dimmed) subtitle, with a filled highlight when selected.
private struct PaletteRow: View {
    let command: PaletteCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.systemImage)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.white : .secondary)
            Text(command.title)
                .foregroundStyle(isSelected ? Color.white : .primary)
            Spacer(minLength: 8)
            if let subtitle = command.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.berthlyAccent : .clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette.\(command.id)")
    }
}

#Preview {
    CommandPaletteView(
        commands: buildPaletteCommands(
            isConnected: true,
            containers: MockContainerService().containers,
            machines: MockContainerService().machines),
        onRun: { _ in },
        isPresented: .constant(true))
    .frame(width: 900, height: 600)
}
