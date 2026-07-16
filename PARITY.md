# CLI parity

How Berthly's GUI maps onto [Apple's `container`](https://github.com/apple/container)
CLI, subcommand by subcommand — and the few places it deliberately doesn't.

> Audited against **container CLI 1.1.0** (2026-07-15). When a change closes or
> opens a gap, update this file in the same commit.

## Containers

| CLI | Berthly |
|---|---|
| `create` | Run sheet with "create only" (provision, leave stopped) |
| `run` | Run sheet — detached or attached foreground |
| `start` / `stop` | Row hover buttons, detail toolbar, menu bar |
| `kill` | "Force Kill" on a running container (SIGKILL) |
| `delete` / `prune` | Row/detail Delete; System → Clean Up |
| `list` | Compute sidebar + list (running and stopped) |
| `inspect` | Detail view Overview/Config tabs |
| `logs` / `logs --boot` | Logs tab with follow, filter, wrap, copy; Output/Boot source picker |
| `stats` | Live CPU/memory/network charts in the detail view |
| `exec` | Integrated terminal tab (SwiftTerm) |
| `copy` | Copy Files sheet, both directions |
| `export` | Export Filesystem… save panel (writes `<name>-rootfs.tar`) |

The Run/Create sheet exposes the full flag surface: env + env-file, ports,
volumes, mounts, tmpfs, networks, labels, entrypoint, workdir, user/uid/gid,
cpus/memory, capabilities add/drop, ulimits, DNS (nameserver, domain, search,
options, no-dns), platform/os/arch, read-only rootfs, init process, cidfile,
interactive/tty, ssh, shm-size, Rosetta, virtualization.

## Images

| CLI | Berthly |
|---|---|
| `build` | Build sheet (context, Dockerfile, tag, platform, build args, labels, target, no-cache, secrets, cpus/memory, pull) with streaming logs |
| `pull` / `push` | Pull/Push sheets with progress; per-platform and insecure-registry options |
| `save` / `load` | Save/Load OCI tar archive sheets |
| `tag` | Tag sheet |
| `delete` / `prune` | Row/detail Delete; Prune… in the Images toolbar; System → Clean Up |
| `list` / `inspect` | Images list + detail view (variants, config, history) |

Berthly additionally persists each image's build context and settings, so
**Rebuild** re-runs a build without re-entering anything — no CLI equivalent.

## Registries

`login`, `logout`, `list` — the Registries page, using the same Keychain
entries as the CLI.

## Machines

| CLI | Berthly |
|---|---|
| `create` | Machine sheet (image, name, cpus, memory, home-mount, no-boot, set-default) |
| `delete` / `stop` | Row/detail actions |
| `list` / `inspect` | Sidebar + detail view |
| `logs` / `logs --boot` | Logs tab with Output/Boot source picker |
| `run` | Terminal tab (login shell in the machine) |
| `set` | Edit sheet (cpus, memory, home-mount; applies on next boot) |
| `set-default` | Set Default action with exclusive badge |

## Volumes & networks

`create`, `delete`, `list`, `inspect`, `prune` — dedicated pages, create
sheets, and Prune… in the Networks toolbar. Volume pruning stays behind its
own explicitly-confirmed action (System → Disk Usage): an unattached volume
can hold real data, so it never rides along with bulk cleanup.

## Builder

`start`, `stop`, `status`, `delete` — the System page's Builder section
(status badge, Start on a stopped builder, Stop, Delete-with-cache-reset).
Builds also start the builder on demand, like the CLI.

## System

| CLI | Berthly |
|---|---|
| `start` / `stop` / `status` | Daemon controls + connection state throughout the app |
| `df` | Disk usage cards with reclaimable-space breakdown |
| `dns` | Local DNS domains list / create / delete |
| `kernel` | Kernel info + Set Kernel sheet (binary, tar/URL, arch, force) |
| `logs` | Daemon Logs viewer |
| `property` | System properties list |
| `version` | Versions shown on the System page |

## Deliberate gaps

Expert or scripting-oriented flags the GUI intentionally leaves to the CLI:

- **`kill --signal` / `stop --signal --time`** — the GUI offers force-kill
  (SIGKILL) as the unwedge action and default stop only; arbitrary signals
  and custom stop timeouts stay a CLI affair.
- **`--publish-socket`** on run/create — forwarding a Unix socket
  host↔container is niche enough to omit from the sheet (the sole run flag
  not exposed).
- **`builder start -c/-m`** — the GUI starts the builder with the configured
  default resources; change them via system properties instead.
- **`logs -n`** — the viewer streams the full log with follow/filter and an
  internal 5,000-line cap; a tail-count option adds nothing in a scrolling UI.
- **Output formatting** (`--format json|yaml|toml`, `--quiet`, `--cidfile`,
  `--debug`) — scripting conveniences with no GUI meaning.
- **`stats` as a fleet-wide table** — Berthly shows richer per-container
  charts instead; an all-containers dashboard would be a new feature, not a
  parity item.
