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

    /// The Keychain's registry logins as `[Registry]`, sorted by host: a mirror of `container
    /// registry list` (`keychain.list()`), with the Keychain as the whole source of truth. Takes
    /// plain `(hostname, username)` pairs because `RegistryInfo`'s memberwise init is internal to
    /// `ContainerizationOS`, so `BerthlyTests` can't construct one.
    nonisolated static func mapRegistries(keychainEntries: [(hostname: String, username: String)]) -> [Registry] {
        keychainEntries
            .map { Registry(host: $0.hostname, username: $0.username) }
            .sorted { $0.host < $1.host }
    }

    func loadRegistriesImpl() async {
        let entries = (try? await Self.keychainList()) ?? []
        registries = Self.mapRegistries(keychainEntries: entries.map { (hostname: $0.hostname, username: $0.username) })
    }

    /// Resolves the scheme and splits `host` into (bare host, port) for `RegistryClient`, as
    /// `container registry login` does (`RegistryLogin.swift`): `RegistryClient`'s host-only init
    /// doesn't split "host:port", so a registry with a port would be mishandled.
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

    /// Remembers `host` (canonicalized by the caller) as one the user marked insecure, so the update
    /// checker and recreate's pull can use HTTP later without re-asking. Deliberately MainActor, not
    /// `nonisolated`: with no `await`, each read-merge-write of `UserDefaults` runs to completion,
    /// so concurrent callers can't interleave.
    static func rememberInsecureHost(_ host: String) {
        let existing = UserDefaults.standard.stringArray(forKey: ImageStaleness.insecureHostsDefaultsKey) ?? []
        UserDefaults.standard.set(ImageStaleness.addingInsecureHost(host, to: existing),
                                  forKey: ImageStaleness.insecureHostsDefaultsKey)
    }

    /// Same offload as `keychainList`: the background update check runs several of these at once, and
    /// a slow Security-framework IPC or ACL prompt would otherwise block cooperative-pool threads and
    /// could stall the whole pool.
    nonisolated static func keychainLookup(hostname: String) async throws -> Authentication {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.lookup(hostname: hostname) })
            }
        }
    }
}
