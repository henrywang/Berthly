// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// "Add a registry" sign-in form — the GUI equivalent of `container registry login`: enter a
/// host + username + token, which is validated against the registry and saved to the Keychain.
struct AddRegistrySheet: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordRevealed = false
    @State private var allowInsecure = false
    @State private var showAdvanced = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !isSubmitting
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "globe",
                title: "Add a Registry",
                subtitle: "Add a host, then sign in — stored in the Keychain"
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Registry host")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("docker.io", text: $host)
                            .accessibilityIdentifier("addRegistryHostField")
                            .textFieldStyle(.roundedBorder)
                            .fontDesign(.monospaced)
                    }

                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Username")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("", text: $username)
                                .accessibilityIdentifier("addRegistryUsernameField")
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                if isPasswordRevealed {
                                    TextField("", text: $password)
                                        .accessibilityIdentifier("addRegistryPasswordField")
                                        .textFieldStyle(.roundedBorder)
                                        .fontDesign(.monospaced)
                                } else {
                                    // A custom secure field, not SwiftUI's `SecureField`, so macOS
                                    // doesn't attach its "Passwords…" AutoFill popup — see
                                    // `NoAutoFillSecureField`. It's borderless; an empty,
                                    // non-interactive `.roundedBorder` field sits behind it to
                                    // provide the exact same native chrome as the other fields
                                    // (matching a hand-drawn border/fill to `.roundedBorder` is
                                    // unreliable — it isn't any AppKit bezel style).
                                    NoAutoFillSecureField(text: $password, onSubmit: { if canSubmit { submit() } })
                                        .padding(.horizontal, 5)
                                        .frame(height: 21)
                                        .background(
                                            TextField("", text: .constant(""))
                                                .textFieldStyle(.roundedBorder)
                                                .allowsHitTesting(false)
                                                .focusable(false)
                                        )
                                }

                                Button {
                                    isPasswordRevealed.toggle()
                                } label: {
                                    Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .help(isPasswordRevealed ? "Hide token" : "Show token")
                                .accessibilityIdentifier("addRegistryRevealPasswordButton")
                            }
                            Text("Token or password for this host")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stored in the macOS Keychain")
                                .font(.caption.weight(.medium))
                            Text("Reused on next push & pull · never written to config.toml")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("""
                                While signed in, macOS may also confirm Keychain access on pulls from this \
                                host — even public images. Sign out from Registries when you're done to stop it.
                                """)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    SheetAdvancedSection(isExpanded: $showAdvanced) {
                        InsecureRegistryToggle(isOn: $allowInsecure)
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(4)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 420)

            Divider()

            HStack {
                Text("Stored in the Keychain · the daemon keeps running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if isSubmitting {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Add & sign in") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                        .keyboardShortcut(.return)
                        .accessibilityIdentifier("addRegistrySubmitButton")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        // Catches Return from the Host/Username fields — the Password field is a raw
        // NSViewRepresentable (see NoAutoFillSecureField) and is wired separately above.
        .submitsOnReturn(when: canSubmit, action: submit)
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await service.signInRegistry(
                    host: trimmedHost, username: trimmedUsername, password: password, insecure: allowInsecure
                )
                isSubmitting = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

#Preview {
    AddRegistrySheet()
        .environment(MockContainerService() as ContainerServiceBase)
}
