// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import Darwin
import Foundation

/// Create Machine's account fields (`machine create --user/--uid/--gid/--home`, container 1.6.0,
/// apple/container#2322), as typed. Blank fields keep upstream's defaults: the host user's name,
/// uid, and gid, and `/home/<user>`.
nonisolated struct MachineAccountInput: Equatable {
    var user = ""
    var uid = ""
    var gid = ""
    var home = ""

    static var hostUsername: String { NSUserName() }
    static var hostUID: UInt32 { getuid() }
    static var hostGID: UInt32 { getgid() }

    /// Checked with upstream's own `Parser.userAccount` so the sheet rejects exactly what
    /// `machineConfigFromFlags` would, but before the image pull instead of after it. Invalid text
    /// must block Create rather than become `nil`, which would silently fall back to the host user.
    var validationError: String? {
        if !trimmed(uid).isEmpty, UInt32(trimmed(uid)) == nil { return "UID must be a whole number." }
        if !trimmed(gid).isEmpty, UInt32(trimmed(gid)) == nil { return "GID must be a whole number." }
        if !trimmed(home).isEmpty, !trimmed(home).hasPrefix("/") { return "Home directory must be an absolute path." }
        guard (try? resolvedAccount()) != nil else { return "User must be a name or UID, optionally followed by :GID." }
        return nil
    }

    /// The home directory upstream will use when the field is blank, for the field's placeholder.
    var defaultHome: String {
        "/home/\((try? resolvedAccount())?.username ?? Self.hostUsername)"
    }

    func apply(to options: inout MachineCreateOptions) {
        options.user = trimmed(user).isEmpty ? nil : trimmed(user)
        options.uid = UInt32(trimmed(uid))
        options.gid = UInt32(trimmed(gid))
        options.home = trimmed(home).isEmpty ? nil : trimmed(home)
    }

    private func resolvedAccount() throws -> (username: String, uid: UInt32, gid: UInt32) {
        try Parser.userAccount(
            user: trimmed(user).isEmpty ? nil : trimmed(user),
            uid: UInt32(trimmed(uid)), gid: UInt32(trimmed(gid)),
            defaultUsername: Self.hostUsername, defaultUID: Self.hostUID, defaultGID: Self.hostGID
        )
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
