// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation

/// Verbatim copy of `MachineUserSetup.script` from apple/container 1.6.1 (Apache 2.0). Since
/// apple/container#2322 (1.6.0) the daemon's guest init no longer has a `-u` user-setup mode;
/// the host runs this as `sh -c` on every boot instead. Berthly's pinned 1.4.1 package predates
/// it, so it's vendored here — replace with `MachineUserSetup.script` once the pin reaches 1.6.x
/// (#192). Expects CONTAINER_USER, CONTAINER_UID, CONTAINER_GID and CONTAINER_HOME, which
/// `MachineConfiguration.processEnvironment` already supplies on both versions.
nonisolated enum MachineUserSetupScript {
    // swiftlint:disable line_length
    // Kept byte-identical to upstream so it can be diffed against future releases.
    static let script = #"""
        set -e

        . /etc/os-release 2>/dev/null || true
        case "${ID:-}" in
            ubuntu|debian)
                CONTAINER_SHELL=$(unset DSHELL; . /etc/adduser.conf 2>/dev/null \
                    && [ -n "${DSHELL:-}" ] \
                    && echo "${DSHELL}") || CONTAINER_SHELL=/bin/bash ;;
            *)
                CONTAINER_SHELL=$(unset SHELL; . /etc/default/useradd 2>/dev/null \
                    && [ -n "${SHELL:-}" ] \
                    && echo "${SHELL}") || CONTAINER_SHELL=/bin/sh ;;
        esac

        if ! getent group "${CONTAINER_GID}" >/dev/null 2>&1; then
            echo "${CONTAINER_USER}:x:${CONTAINER_GID}:" >> /etc/group
        fi

        existing_by_uid=$(getent passwd "${CONTAINER_UID}" 2>/dev/null) || true
        existing_by_name=$(getent passwd "${CONTAINER_USER}" 2>/dev/null) || true

        if [ -n "${existing_by_uid}" ] || [ -n "${existing_by_name}" ]; then
            if [ "${existing_by_uid}" != "${existing_by_name}" ]; then
                echo "container machine: refusing to provision user '${CONTAINER_USER}' (uid ${CONTAINER_UID}): a different account in this image already uses this uid or username" >&2
                exit 1
            fi
            # Otherwise this is our own account from a previous boot: nothing to do.
        else
            if [ -e "${CONTAINER_HOME}" ]; then
                echo "container machine: refusing to use existing path '${CONTAINER_HOME}' as the home directory for user '${CONTAINER_USER}'" >&2
                exit 1
            fi

            echo "${CONTAINER_USER}:x:${CONTAINER_UID}:${CONTAINER_GID}::${CONTAINER_HOME}:${CONTAINER_SHELL}" >> /etc/passwd
            echo "${CONTAINER_USER}:!:$(($(date +%s) / 86400)):0:99999:7:::" >> /etc/shadow

            mkdir -p "${CONTAINER_HOME}"
            if [ -d /etc/skel ]; then
                cp -a /etc/skel/. "${CONTAINER_HOME}"
            fi
            chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${CONTAINER_HOME}"
        fi

        mkdir -p /etc/sudoers.d
        sudoers_file=$(echo "${CONTAINER_USER}" | tr '.' '_')
        echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${sudoers_file}"
        chmod 440 "/etc/sudoers.d/${sudoers_file}"
        """#
    // swiftlint:enable line_length
}
