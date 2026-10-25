// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import ContainerizationError
import Foundation

/// Builds and checks `--network <name>[,alias=NAME]...` specs (DNS aliases, container 1.6.0,
/// apple/container#2390) from the Run sheet's network rows.
nonisolated enum NetworkAttachmentSpec {
    /// The Aliases field takes names separated by commas and/or whitespace.
    static func aliases(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    static func spec(network: String, aliasesText: String) -> String {
        ([network] + aliases(from: aliasesText).map { "alias=\($0)" }).joined(separator: ",")
    }

    /// Upstream's own `Parser.network`, so a malformed alias is caught before the image fetch.
    /// The daemon's placement rules (fully qualified unless a default DNS domain is set; a `.name`
    /// subtree must sit below the hostname or an exact alias) live in its non-exported
    /// `AliasPolicy` and still surface from the daemon at create time.
    static func validationError(network: String, aliasesText: String) -> String? {
        do {
            _ = try Parser.network(spec(network: network, aliasesText: aliasesText))
            return nil
        } catch let error as ContainerizationError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// Mock mode's stand-in for the daemon's stored `AttachmentOptions.aliases`.
    static func aliasesByNetwork(_ specs: [String]) -> [String: [String]] {
        specs.reduce(into: [:]) { result, spec in
            let parsed = parse(spec)
            if !parsed.aliases.isEmpty { result[parsed.network, default: []] += parsed.aliases }
        }
    }

    /// Splits a spec back into its network name and normalized aliases. An unparseable spec
    /// keeps its leading name with no aliases.
    static func parse(_ spec: String) -> (network: String, aliases: [String]) {
        guard let parsed = try? Parser.network(spec) else {
            return (String(spec.prefix { $0 != "," }), [])
        }
        return (parsed.name, parsed.aliases)
    }
}
