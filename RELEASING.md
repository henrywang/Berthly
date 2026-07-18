# Releasing Berthly

Berthly is distributed outside the Mac App Store (it must run unsandboxed to
talk to the `container` daemon) and self-updates via [Sparkle 2] from GitHub
Releases. `scripts/release.sh` runs the whole pipeline.

[Sparkle 2]: https://github.com/sparkle-project/Sparkle

## Cutting a release

1. **Bump versions** in Xcode: project → target *Berthly* → *General* →
   *Identity*:
   - **Version** (`MARKETING_VERSION`) — the human-facing version; becomes the
     git tag `v<version>` and the DMG name.
   - **Build** (`CURRENT_PROJECT_VERSION`) — **must increase every release.**
     Sparkle compares build numbers (`CFBundleVersion`), not version strings,
     to decide whether an update is newer; a release that reuses a build
     number is invisible to installed copies. Increment by 1, forever.
2. **Commit** (the script warns on a dirty tree — the archive would include
   uncommitted changes).
3. **Run** `scripts/release.sh`. It does, in order:
   - preflight: `gh` authenticated, Developer ID identity present, Sparkle
     tools in DerivedData, tag `v<version>` not already released
   - `xcodebuild archive` + `-exportArchive` with the Developer ID method
   - build `Berthly-<version>.dmg` via `scripts/dmg.sh` — branded
     drag-to-install window (background, icon positions, volume icon; assets
     from `design/dmg/`; needs Finder Automation permission on first run) —
     then sign it, notarize it (`notarytool --wait`, typically a few
     minutes), staple the ticket to the DMG
   - `generate_appcast` — signs the DMG with the Sparkle EdDSA key from the
     login keychain and writes a single-entry `appcast.xml` whose download
     URL points at this release's assets
   - `gh release create v<version>` with the DMG and `appcast.xml` attached,
     release notes written from the test gate's results (see
     `scripts/release.sh`'s Release notes step)
4. **Smoke-test the update path** (from the second release onward): launch an
   older installed build and use *Berthly → Check for Updates…* — the Sparkle
   dialog should offer the new version and *Install and Relaunch* cleanly.

Installed apps find updates via `SUFeedURL` =
`https://github.com/henrywang/Berthly/releases/latest/download/appcast.xml` —
`latest/download` always resolves to the newest release's attached feed, so
publishing the release is the whole deployment.

## One-time machine setup

Already done on the original release Mac (2026-07-14). To release from a
different machine:

1. **Developer ID Application certificate** — export the identity from
   Keychain Access as a `.p12` on the old Mac and import it, or create a new
   one (Xcode → Settings → Accounts → *Manage Certificates…*). Apple caps
   Developer ID certs per account, so prefer migrating over minting.
2. **Notarization credentials** — create an app-specific password at
   <https://account.apple.com> (*Sign-In and Security → App-Specific
   Passwords*), then:

   ```sh
   xcrun notarytool store-credentials berthly-notary \
     --apple-id <apple-id-email> --team-id 4H628G9PWH \
     --password <app-specific-password>
   ```

   (The script reads the profile name from `$BERTHLY_NOTARY_PROFILE`,
   defaulting to `berthly-notary`.)
3. **Sparkle EdDSA private key** — import the backed-up key with
   `generate_keys -f <file>` (tools live under
   `DerivedData/…/SourcePackages/artifacts/sparkle/Sparkle/bin/`). **Never
   regenerate it**: installed apps only accept updates signed by the key
   matching the `SUPublicEDKey` baked into their `Config/Info.plist`, so a
   new key strands every existing install on manual re-downloads. If you
   don't have a backup yet: `generate_keys -x <file>` and store it in a
   password manager.

## Design notes

- The appcast intentionally carries **only the newest release**: each GitHub
  release hosts its own assets, so a multi-entry feed would need per-entry
  URL bookkeeping to avoid stale links. The cost is no Sparkle delta updates
  (every update is a full download) — revisit if the app grows or release
  cadence makes that annoying.
- `SUPublicEDKey`, `SUFeedURL`, and `SUEnableAutomaticChecks` live in
  `Config/Info.plist`, merged into the generated Info.plist via
  `INFOPLIST_FILE`.
- The in-app updater surface is `Berthly/Core/UpdaterService.swift`
  (*Check for Updates…* menu item, Settings → General → Updates toggles).
  The updater never starts in test runs — see
  `UpdaterService.shouldStartUpdater(environment:)`.
