// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import ContainerizationExtras

/// Picks http vs https for a registry connection.
///
/// apple/container 1.3.0 ([apple/container#2100](https://github.com/apple/container/pull/2100))
/// deleted `RequestScheme.auto` and the `isInternalHost` detection behind it: `schemeFor` now
/// returns https for every host unless the caller already chose http. Without that heuristic a
/// plain-HTTP registry on localhost or a private network is unreachable unless the user ticks
/// "Allow insecure registry". This restores the removed rule — localhost, the daemon's internal
/// DNS domain, and the RFC 1918 / loopback IPv4 ranges resolve to http; everything else to https
/// — for the paths where Berthly controls a single host.
enum RegistrySchemeResolver {

    /// `isInternalHost` is a verbatim port of the detection apple/container#2100 removed.
    static func scheme(forHost host: String, insecure: Bool, internalDnsDomain: String?) -> RequestScheme {
        if insecure { return .http }
        return isInternalHost(host: host, internalDnsDomain: internalDnsDomain) ? .http : .https
    }

    /// Resolves the registry host from an image reference via `ImageStaleness.registryHost`
    /// (case-folded, Docker Hub alias applied — neither matters for an internal host). A
    /// reference with no registry (e.g. `alpine:latest`) has no internal host, so it resolves
    /// to https.
    static func scheme(forReference reference: String, insecure: Bool, internalDnsDomain: String?) -> RequestScheme {
        if insecure { return .http }
        guard let host = ImageStaleness.registryHost(for: reference) else { return .https }
        return isInternalHost(host: host, internalDnsDomain: internalDnsDomain) ? .http : .https
    }

    /// A verbatim port of the `RequestScheme.isInternalHost` apple/container#2100 removed. A
    /// `host:port` string won't match `localhost` or parse as an IPv4 address, so a ported
    /// local registry stays https unless the insecure toggle forces http — same as pre-1.3.0.
    static func isInternalHost(host: String, internalDnsDomain: String?) -> Bool {
        if host == "localhost" { return true }
        if let internalDnsDomain, host.hasSuffix(".\(internalDnsDomain)") { return true }
        guard let value = (try? IPv4Address(host))?.value else { return false }
        if value & 0xff00_0000 == 0x0a00_0000 { return true }  // 10.0.0.0/8
        if value & 0xff00_0000 == 0x7f00_0000 { return true }  // 127.0.0.0/8
        if value & 0xffff_0000 == 0xc0a8_0000 { return true }  // 192.168.0.0/16
        if value & 0xfff0_0000 == 0xac10_0000 { return true }  // 172.16.0.0/12
        return false
    }
}
