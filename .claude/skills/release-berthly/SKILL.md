---
name: release-berthly
description: Cut a new Berthly release — bump version, run scripts/release.sh, write a real "What's Changed" summary from the actual diff, and verify the published artifact. Use when the user asks to release, ship, cut a version, or publish a new Berthly build.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Bash
  - Grep
---

# /release-berthly

Drives a full Berthly release end to end. `scripts/release.sh` does the
mechanical work (test gate, archive, DMG, notarize, staple, appcast,
`gh release create`); this skill supplies the judgment `release.sh`
can't: picking the version, writing release notes that actually describe
the change, deciding how to resume if a step fails, and verifying the
published artifact is real. See `RELEASING.md` for the mechanical
reference; this skill is the workflow around it.

Arguments passed: `$ARGUMENTS` (optional — a version number if the user
already knows what they want, e.g. `/release-berthly 1.1.0`)

---

## 1. Orient before touching anything

- `git status --short` — refuse to proceed silently on a dirty tree;
  `release.sh` will archive whatever's on disk, uncommitted or not.
- `gh release list --repo henrywang/Berthly` and `git tag` — find the
  latest published tag. This is `PREV_TAG` for both the version-bump
  decision and the changelog.
- `git log --oneline <PREV_TAG>..HEAD` and `git diff <PREV_TAG>..HEAD --stat`
  — read what actually changed. This is the input for the release notes
  in step 4, so do this early, not after the DMG is already built.

## 2. Decide and set the version

Two independent numbers live in `Berthly.xcodeproj/project.pbxproj`:

- **`MARKETING_VERSION`** (e.g. `1.0.1`) — human-facing, becomes the git
  tag `v<version>` and the DMG name. Pick semver-ish: patch for
  fixes/infra, minor for new user-facing features. This is a judgment
  call — state your reasoning and let the user confirm or override
  before proceeding, don't just pick silently. If `$ARGUMENTS` gave a
  version, use it.
- **`CURRENT_PROJECT_VERSION`** (the build number) — **must be strictly
  greater than every previous release's build number**, always, no
  exceptions. Sparkle compares this number (`CFBundleVersion`), not the
  marketing string, to decide if an update is newer — reusing or
  lowering it makes the release invisible to installed copies that
  already have a higher build number. Read the current value from the
  **Berthly app target** (not the test targets, see below) and set the
  new one to current + 1.

Bump both via `sed` on `project.pbxproj`, or ask the user to do it in
Xcode (target *Berthly* → *General* → *Identity*) if they'd rather —
either is fine, just verify the result afterward:

```sh
xcodebuild -project Berthly.xcodeproj -scheme Berthly -showBuildSettings 2>/dev/null \
  | grep -m1 MARKETING_VERSION
```

**Only the `Berthly` app target's numbers matter.** `project.pbxproj` has
separate `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` pairs per target
(app, `BerthlyTests`, `BerthlyUITests`, `BerthlyE2ETests`) — Xcode's
target-settings panel only edits whichever target is selected, so a bump
done through the GUI commonly touches only the app target and leaves the
test targets stale. That's fine: `xcodebuild -showBuildSettings` for the
`Berthly` scheme's build action reports only the app target, test
bundles never ship, and nothing else in the repo reads their version
fields. Don't "fix" the test targets' numbers — it's cosmetic churn with
no functional effect, confirmed by grepping the whole repo for any
script/CI that reads them (there is none).

Update README.md's Download badge in the same commit: it links directly
to `releases/latest/download/Berthly-<version>.dmg` (not the releases
page), which only resolves for the exact filename attached to the
current latest release. Bump the version in that URL to match. Forgetting
this 404s the badge rather than silently serving a stale build — that's
deliberate, but only if you don't skip the step.

Commit the version bump (project.pbxproj + README.md) by itself before
running the release script — `release.sh` warns on a dirty tree rather
than blocking, so commit anyway for a clean archive.

## 3. Confirm, then run the release script

**Stop and confirm with the user before this step.** It submits to
Apple's real notarization service (a few minutes' wait) and, if it
completes, creates a real, public-in-the-repo GitHub release + git tag.
Don't just run it because the version is bumped.

```sh
scripts/release.sh
```

### If it fails partway through

Don't blindly re-run from scratch — `release.sh` starts with `rm -rf
dist`, which throws away a possibly-still-valid DMG and, worse, would
trigger a second unnecessary notarization submission. Instead:

1. Check what already happened: `ls dist/`, `gh release view v<version>`
   (does the release already exist on GitHub? if so, stop — don't
   double-publish), `ls dist/appcast/` (did it get past DMG creation?).
2. If `dist/<name>.dmg` exists, verify it independently before deciding
   whether to trust it:
   ```sh
   codesign --verify --deep --strict dist/Berthly-<version>.dmg
   xcrun stapler validate dist/Berthly-<version>.dmg
   ```
   **Do not use `spctl -a` to validate a `.dmg`** — it is unreliable for
   disk images from the CLI (it's built around validating `.app`
   bundles) and reports false rejections even for a correctly signed,
   notarized DMG: `-t execute` (the default) says "does not seem to be
   an app," and `-t open` says "Insufficient Context" because Gatekeeper's
   real open-assessment needs LaunchServices quarantine-event context no
   CLI invocation can synthesize. `codesign --verify` + `stapler
   validate` are what actually mean something here. (`release.sh`
   already uses these instead of `spctl` for exactly this reason — if
   you ever see `spctl -a` reintroduced against a `.dmg` anywhere in this
   repo, that's a regression, not a real failure.)
3. If the DMG verifies clean, resume manually instead of restarting:
   recompute the test-gate numbers from the existing `dist/test.log` /
   `dist/tests.xcresult` (don't re-run the test suite), rebuild
   `dist/appcast/` from the existing DMG, run `generate_appcast`, then
   continue at step 4 below. Only fall back to a full `rm -rf dist &&
   scripts/release.sh` re-run if the DMG itself doesn't verify.

## 4. Write the real release notes

`release.sh` only ever writes a bare "Testing" evidence block (test
counts, coverage percentages) plus a "Full Changelog" compare link — it
has no idea what the release actually changed, by design (see the
comment above the notes-generation step in `release.sh`). Left as-is,
the published release says nothing about what's different. Always
follow up:

1. Using the `git log`/`git diff` you already read in step 1, draft a
   **"What's Changed"** section in your own words: what changed, why,
   and what a user or developer reading the release should understand
   about its impact. Look at `git show <PREV_TAG>` and the commits since
   for the actual substance — don't paraphrase commit subject lines,
   explain the change the way you'd explain it to someone who wasn't
   there. If a change fixed a real bug, say what broke and for whom.
2. Prepend it to the existing `## Testing` section and changelog link
   (don't discard those — they're real evidence, not boilerplate).
3. Publish:
   ```sh
   gh release edit v<version> --repo henrywang/Berthly --notes-file <file>
   ```
   **Confirm with the user before this edit** if the release was already
   auto-created by `release.sh` and they haven't seen the draft — show
   them the notes first.

## 5. Verify the published release

- `gh api repos/henrywang/Berthly/releases/tags/v<version> --jq '.assets[]'`
  — confirm both the `.dmg` and `appcast.xml` are attached with sane
  sizes. (Plain `curl` on the public download URL will 404 if the repo
  is private — that's a known, separate, unrelated issue, not a release
  failure; use `gh api` for a real check.)
- If this isn't the first release, this is the point to actually test
  the update path: launch an older installed build and use *Berthly →
  Check for Updates…* — Sparkle should offer the new version. This is
  the only way to know the in-app auto-update actually works, not just
  the manual download.
- Optionally run `scripts/smoke.sh` against a freshly downloaded copy of
  the new DMG (mount it, or extract with `ditto -x -k` — never plain
  `unzip`, though this stopped being a zip-specific footgun once the
  release moved to DMG) to confirm the installed app's signature and
  Sparkle feed check out.
- Confirm README's Download badge actually resolves:
  `curl -sI -L https://github.com/henrywang/Berthly/releases/latest/download/Berthly-<version>.dmg`
  should end in a `200`/redirect chain to the asset, not a `404` — this
  is the check that catches a forgotten step 2 bump.

## Don'ts

- Don't run `scripts/release.sh` or any `gh release create`/`gh release
  edit` without the user's explicit go-ahead first — these are real,
  hard-to-reverse, publicly-visible actions (to anyone with repo
  access), not local reversible edits.
- Don't reuse or lower `CURRENT_PROJECT_VERSION`.
- Don't validate a `.dmg` with `spctl -a`.
- Don't let the release publish with only the bare Testing-section notes
  — that's a silent gap, not acceptable output, even though the script
  won't error on it.
