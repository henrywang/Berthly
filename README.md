<p align="center">
  <img src="design/icon/berthly-dock-1024.svg" width="150" alt="Berthly app icon — a dock bollard with a mooring line made fast">
</p>

<h1 align="center">Berthly</h1>

<p align="center">
  <a href="https://github.com/henrywang/Berthly/releases/latest/download/Berthly-1.1.0.dmg"><img src="https://img.shields.io/badge/Download-macOS-black?logo=apple&logoColor=white" alt="Download for macOS"></a>
  <a href="https://github.com/henrywang/Berthly/actions/workflows/ci.yml"><img src="https://github.com/henrywang/Berthly/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/henrywang/Berthly/actions/workflows/ci.yml"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fhenrywang%2FBerthly%2Fbadges%2Fcoverage.json" alt="Logic coverage"></a>
</p>

<p align="center">
  <a href="https://berthly.net"><b>berthly.net</b></a>
</p>

A native macOS app for [Apple's `container`](https://github.com/apple/container) — build images, run containers and machines, manage networks and volumes, and tail logs from a real GUI instead of the command line.

Berthly lives in your menu bar and opens a full SwiftUI window, giving Apple's container tooling the Docker Desktop-style experience it's missing.

![Berthly demo — open the menu-bar monitor, inspect live container metrics, and drag a Dockerfile from Finder to start a pre-filled image build](https://github.com/henrywang/Berthly/releases/download/media-assets/berthly-demo.gif)

> **Berthly 2.0 is in progress** — multi-service Projects, volume backups, actionable diagnostics, and more, built around what makes Apple's container runtime distinct rather than cloning Docker Desktop or OrbStack feature-for-feature. Track it on the [public roadmap](https://github.com/users/henrywang/projects/3).

## Features

- **Images** — list, pull from a registry, build from a Dockerfile, and inspect layers and metadata.
- **Containers** — create and run containers, view details, and stream logs live.
- **Machines** — create and manage VMs, set the kernel, and inspect resources.
- **Networks & volumes** — create, list, and remove them without touching a terminal.
- **Registries** — sign in to private registries and manage saved hosts.
- **Integrated terminal** — a real terminal attached to your containers, built on SwiftTerm.
- **Command palette** — jump to any action with a keystroke.
- **Menu-bar presence** — quick status and controls without leaving what you're doing.
- **Keyboard-first** — ⌘K palette, ⌘1–6 section switching, ⌘⌥1–3 detail tabs, and full menu shortcuts for every action.

![The command palette (⌘K) matching lifecycle actions for a container](design/screenshots/command-palette.png)

## Beyond the CLI

A GUI that only mirrored commands wouldn't be worth installing. Berthly is built
around the *workflow*, with a tier of features the CLI doesn't have:

- **Drag-and-drop builds** — drag a `Dockerfile`/`Containerfile` from Finder
  onto the window to open the Build sheet pre-filled with the resolved
  context and Dockerfile path.
- **Rebuild in one click** — every image build's context and flags are
  remembered, so re-running a build never means re-entering anything.
- **Watch without watching** — live CPU/memory/network charts per container,
  pinned favorites in the menu bar, and a notification when a pinned container
  or machine changes state while you're elsewhere.
- **Builds keep going** — close the build sheet and keep working; the toolbar
  indicator tracks progress and surfaces failures.
- **Zero to running** — Berthly can install Apple's signed `container`
  toolchain, then start and monitor the daemon for you.
- **Disk hygiene at a glance** — reclaimable-space badges on Images and
  Volumes, with confirmed one-click pruning.
- **Image updates, Watchtower-style** — Berthly periodically compares your
  pulled tags against their registries and badges stale images and the
  containers running them; "Recreate with Latest Image" pulls and rebuilds the
  container with its exact configuration, volumes intact.

And yes — Berthly also covers the `container` CLI's full feature surface — see
[PARITY.md](PARITY.md) for the subcommand-by-subcommand mapping and the few
expert flags left to the CLI.

## Requirements

- **Apple Silicon Mac** — `container` runs Linux containers in lightweight VMs and requires Apple Silicon.
- **macOS 26 or later.**
- **[Apple's `container`](https://github.com/apple/container) installed and running.** Berthly is a GUI on top of it; it can help you install and start the daemon, but it drives the same underlying tooling.

## Install

Download the latest `Berthly-<version>.dmg` from
[berthly.net](https://berthly.net) or
[Releases](https://github.com/henrywang/Berthly/releases/latest), open it, and
drag **Berthly.app** into Applications. The app is Developer ID–signed and
notarized by Apple, so it opens without warnings. Updates arrive in-app
(Berthly → Check for Updates…).

Or build from source:

## Building

Berthly is an Xcode project. It links against Apple's [`container`](https://github.com/apple/container) and [`containerization`](https://github.com/apple/containerization) Swift packages, resolved automatically via Swift Package Manager.

```sh
git clone https://github.com/henrywang/Berthly.git
cd Berthly
open Berthly.xcodeproj
```

Then build and run the **Berthly** scheme (⌘R). Package resolution runs on first open and may take a few minutes.

> **Note:** building the container/containerization dependencies requires the Swift toolchain that ships with the matching Xcode; make sure your Xcode is current.

## Testing

- **Unit tests** (`BerthlyTests`) use [Swift Testing](https://github.com/apple/swift-testing).
- **UI tests** (`BerthlyUITests`) use XCUITest and can run against a mock service for determinism.

```sh
xcodebuild test -scheme Berthly -destination 'platform=macOS'
```

## Privacy & security

Berthly is a local tool, and it behaves like one:

- **Everything stays on your Mac.** Berthly talks to the local `container`
  daemon over XPC. There is no telemetry, no analytics, and no crash
  reporting.
- **Network traffic is limited to what you can see.** Image pulls, pushes,
  and registry sign-ins go to the registries *you* configure — the same ones
  the `container` CLI would contact. Beyond that, Berthly contacts GitHub in
  exactly two cases: checking for Berthly updates (Sparkle fetches the
  release feed from this repo's GitHub Releases — disable it in Settings if
  you prefer), and downloading Apple's signed `container` installer when you
  use the guided install/upgrade flow.
- **Registry credentials live in your macOS Keychain**, in the very same
  Keychain items `container registry login` uses. Berthly never stores
  credentials anywhere else.
- **Not sandboxed, by necessity.** Berthly manages the container daemon
  (XPC, `launchctl`) and works with your local files for builds and volume
  mounts — capabilities the App Sandbox doesn't allow. The code is open;
  audit what it does.

Found a vulnerability? Please report it privately — see
[SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for how to
build, test, and submit changes. Bug reports and feature requests are welcome
via [issues](https://github.com/henrywang/Berthly/issues).

## License

Licensed under the [Apache License 2.0](LICENSE).
