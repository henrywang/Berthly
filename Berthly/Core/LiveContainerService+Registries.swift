// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AsyncHTTPClient
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import Logging
import MachineAPIClient
import NIOCore
import NIOHTTP1
import NIOPosix
import TerminalProgress
internal import ContainerPersistence
internal import ContainerPlugin

extension LiveContainerService {
    // MARK: - Registries

    /// Same Keychain security domain `container registry login/logout/list` use
    /// (`ContainerAPIClient.Constants.keychainID`) — Berthly reads/writes the identical items the
    /// CLI and daemon do, in-process, no shelling out.
    private nonisolated static let registryKeychain = KeychainHelper(securityDomain: Constants.keychainID)

    /// Maps the Keychain's registry logins straight to `[Registry]`, sorted by host for a stable
    /// display order — a faithful mirror of `container registry list`, which is likewise just
    /// `keychain.list()`. No curated defaults, no persisted "signed-out" rows: the Keychain is
    /// the whole source of truth. Shown verbatim (e.g. `registry-1.docker.io`), same as the CLI.
    ///
    /// Takes plain `(hostname, username)` pairs rather than `RegistryInfo` directly: that type's
    /// memberwise init is internal to `ContainerizationOS` (only `KeychainQuery` itself
    /// constructs it), so it can't be fabricated from `BerthlyTests` — and we only need these two.
    nonisolated static func mapRegistries(keychainEntries: [(hostname: String, username: String)]) -> [Registry] {
        keychainEntries
            .map { Registry(host: $0.hostname, username: $0.username) }
            .sorted { $0.host < $1.host }
    }

    func loadRegistriesImpl() async {
        let entries = (try? await Self.keychainList()) ?? []
        registries = Self.mapRegistries(keychainEntries: entries.map { (hostname: $0.hostname, username: $0.username) })
    }

    /// Resolves the scheme and splits `host` into (bare host, port) for a `RegistryClient`
    /// connection — mirrors `container registry login` (`RegistryLogin.swift`): build a URL from
    /// scheme+host so a `host:port` string (e.g. a local test registry) splits into a bare host
    /// and an explicit port. `RegistryClient`'s host-only initializer doesn't split "host:port"
    /// itself, so passing the raw string straight through mishandles any registry with a port.
    /// Pure and `nonisolated` so it's testable without a live daemon (`LiveContainerService.buildArguments(for:)`
    /// is the pattern) — no `Process`/XPC involved.
    nonisolated static func resolveRegistryConnectionTarget(
        host: String, insecure: Bool, internalDnsDomain: String?
    ) throws -> (scheme: RequestScheme, host: String, port: Int?) {
        let scheme = RegistrySchemeResolver.scheme(
            forHost: host, insecure: insecure, internalDnsDomain: internalDnsDomain
        )
        guard let url = URL(string: "\(scheme.rawValue)://\(host)"), let urlHost = url.host else {
            throw ContainerCLIError(exitCode: 1, message: "\(host) is not a valid registry host.")
        }
        return (scheme, urlHost, url.port)
    }

    /// apple/container 1.3.1 (CVE-2026-65388) made `RegistryClient` refuse the token exchange
    /// whenever an http registry answers with a `WWW-Authenticate` challenge, or the token realm
    /// isn't HTTPS / isn't in the registry's registrable domain. Berthly routes `localhost`, the
    /// internal DNS domain, and RFC 1918 hosts to http (`RegistrySchemeResolver`), and "Allow
    /// insecure registry" forces http for any host — so signing in to a registry that enforces
    /// auth over one of those http paths now fails here (`client.ping()` throws
    /// `insecureCredentialExchange` on the challenge). A plain http registry with no auth is fine.
    nonisolated static func insecureRegistryAuthMessage(host: String) -> String {
        "Can't sign in to \(host): apple/container 1.3.1 refuses to send credentials to a registry "
            + "over plain HTTP, or to a token server outside the registry's own domain (CVE-2026-65388). "
            + "This registry needs an HTTPS endpoint."
    }

    func signInRegistryImpl(host: String, username: String, password: String, insecure: Bool) async throws {
        let host = Reference.resolveDomain(domain: host.trimmingCharacters(in: .whitespaces))
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Host, username, and token are required.")
        }

        let containerSystemConfig = await resolvedSystemConfig()
        let target = try Self.resolveRegistryConnectionTarget(
            host: host, insecure: insecure, internalDnsDomain: containerSystemConfig.dns.domain
        )
        let client = RegistryClient(
            host: target.host,
            scheme: target.scheme.rawValue,
            port: target.port,
            authentication: BasicAuthentication(username: username, password: password),
            retryOptions: RetryOptions(maxRetries: 3, retryInterval: 300_000_000, shouldRetry: { $0.status.code >= 500 })
        )
        do {
            try await client.ping()
        } catch let error as RegistryClient.Error {
            if case .insecureCredentialExchange = error {
                throw ContainerCLIError(exitCode: 1, message: Self.insecureRegistryAuthMessage(host: target.host))
            }
            throw error
        }

        do {
            try await Self.keychainSave(hostname: host, username: username, password: password)
        } catch let error as KeychainQuery.Error {
            throw Self.friendlyError(for: error, host: host) ?? error
        }
        if insecure {
            Self.rememberInsecureHost(ImageStaleness.foldedBareHost(host))
        }
        await loadRegistries()
    }

    func signOutRegistryImpl(host: String) async throws {
        let host = Reference.resolveDomain(domain: host.trimmingCharacters(in: .whitespaces))
        do {
            try await Self.keychainDelete(hostname: host)
        } catch let error as KeychainQuery.Error {
            throw Self.friendlyError(for: error, host: host) ?? error
        }
        await loadRegistries()
    }

    /// macOS Keychain refuses to let a different process identity delete/overwrite an item —
    /// `container login` from the CLI creates entries Berthly can see (`list()`) but can't take
    /// ownership of. `errSecInvalidOwnerEdit` is macOS's exact signal for that case.
    private nonisolated static let errSecInvalidOwnerEdit: Int32 = -25244

    private nonisolated static func friendlyError(for error: KeychainQuery.Error, host: String) -> RegistryOperationError? {
        if case .unhandledError(let status) = error, status == errSecInvalidOwnerEdit {
            return RegistryOperationError(host: host)
        }
        return nil
    }

    /// `KeychainHelper`'s Security-framework calls are synchronous and can block on IPC to
    /// securityd — offload to a background queue rather than stalling the main actor.
    private nonisolated static func keychainList() async throws -> [RegistryInfo] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.list() })
            }
        }
    }

    private nonisolated static func keychainSave(hostname: String, username: String, password: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.save(hostname: hostname, username: username, password: password) })
            }
        }
    }

    private nonisolated static func keychainDelete(hostname: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.delete(hostname: hostname) })
            }
        }
    }

    /// Remembers `host` (already canonicalized by the caller via `ImageStaleness.registryHost`/
    /// `foldedBareHost`) as one the user has explicitly told Berthly is insecure — so the
    /// background update checker and recreate's own pull can use HTTP for it later without
    /// re-asking. Deliberately **not** `nonisolated`: it inherits this class's `@MainActor`
    /// isolation like every other instance-triggered write here, which statically guarantees no
    /// two callers' read-merge-write of `UserDefaults` can interleave — MainActor code only
    /// yields at `await`, and this function has none, so each call runs to completion before
    /// anything else on MainActor can touch the key. UserDefaults itself needs no background-
    /// queue offload the way Keychain does (no Security-framework IPC involved).
    static func rememberInsecureHost(_ host: String) {
        let existing = UserDefaults.standard.stringArray(forKey: ImageStaleness.insecureHostsDefaultsKey) ?? []
        UserDefaults.standard.set(ImageStaleness.addingInsecureHost(host, to: existing),
                                  forKey: ImageStaleness.insecureHostsDefaultsKey)
    }

    /// Same offload as `keychainList`/`keychainSave`/`keychainDelete` — used by the background
    /// image-update check, which runs several of these concurrently in a task group. Without the
    /// offload, a slow Security-framework IPC or an ACL prompt would block the calling
    /// cooperative-thread-pool thread, and with only a handful of threads in the pool, a few
    /// concurrent private-registry checks could stall the whole pool indefinitely.
    nonisolated static func keychainLookup(hostname: String) async throws -> Authentication {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.lookup(hostname: hostname) })
            }
        }
    }
}
