# Berthly

A native macOS app for [Apple's `container`](https://github.com/apple/container) — build images, run containers and machines, manage networks and volumes, and tail logs from a real GUI instead of the command line.

Berthly lives in your menu bar and opens a full SwiftUI window, giving Apple's container tooling the Docker Desktop-style experience it's missing.

## Features

- **Images** — list, pull from a registry, build from a Dockerfile, and inspect layers and metadata.
- **Containers** — create and run containers, view details, and stream logs live.
- **Machines** — create and manage VMs, set the kernel, and inspect resources.
- **Networks & volumes** — create, list, and remove them without touching a terminal.
- **Registries** — sign in to private registries and manage saved hosts.
- **Integrated terminal** — a real terminal attached to your containers, built on SwiftTerm.
- **Command palette** — jump to any action with a keystroke.
- **Menu-bar presence** — quick status and controls without leaving what you're doing.

## Requirements

- **Apple Silicon Mac** — `container` runs Linux containers in lightweight VMs and requires Apple Silicon.
- **macOS 26.5 or later.**
- **[Apple's `container`](https://github.com/apple/container) installed and running.** Berthly is a GUI on top of it; it can help you install and start the daemon, but it drives the same underlying tooling.

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

## License

Licensed under the [Apache License 2.0](LICENSE).
