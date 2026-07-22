# Manual tests

Fixtures for QA scenarios that automation can't reliably cover — currently
just one: dragging a Dockerfile/Containerfile from Finder onto Berthly's main
window to open a pre-filled Build sheet. XCUITest has no public API to
synthesize a real Finder file-promise drag (`NSItemProvider`), so this has to
be exercised by hand.

This is a companion to `BerthlyTests` (unit), `BerthlyUITests` (mock-mode UI),
and `BerthlyE2ETests` (real-daemon UI) — same idea, but for the one class of
interaction none of those three can drive. Nothing here builds or runs as an
Xcode target; it's just files to drag.

## Drag-and-drop build

Build and run Berthly (⌘R), open this folder in Finder
(`BerthlyManualTests/DragDropBuild/`), and drag each item below onto the main
window — the whole window is a drop target, including the sidebar, the
Images/Compute lists, and any open detail pane. Check the result against the
"Expected" column.

| # | Drag this | Expected | Why |
| --- | --- | --- | --- |
| 01 | `01-canonical-dockerfile/Dockerfile` | Build sheet opens, both fields filled | Canonical name |
| 02 | `02-canonical-containerfile/Containerfile` | Build sheet opens, both fields filled | Canonical alt name |
| 03 | `03-prefixed-variant/Dockerfile.prod` | Build sheet opens, both fields filled | `Dockerfile.<suffix>` naming |
| 04 | `04-suffixed-variant/backend.Dockerfile` | Build sheet opens, both fields filled | `<prefix>.Dockerfile` naming |
| 05 | `05-non-matching-name/README.md` | Rejection banner: "Drop a Dockerfile or Containerfile to build." | Name doesn't match; content is never read |
| 06 | `06-symlink-name-matches-target-doesnt/Dockerfile` | **Accepted** — sheet opens pointing at `05-non-matching-name/README.md`'s real location | Symlink's own visible name (`Dockerfile`) is what's validated, not its target |
| 07 | `07-symlink-name-mismatch/build-file` | **Rejected** — same banner as #05 | Symlink's own name (`build-file`) fails the check; its target (`Dockerfile`) is never even resolved |
| 08 | `08-broken-symlink-named-dockerfile/Dockerfile` | Rejection banner: "Couldn't read the dropped file." | Name matches, but the symlink's target doesn't exist |
| 09 | `09-directory-named-dockerfile/Dockerfile` | Rejection banner: "Drop a Dockerfile or Containerfile to build." | Name matches, but it's a directory, not a file |
| 10 | `10-path-with-spaces-and-non-ascii/Café Project/Dockerfile` | Build sheet opens, both fields filled correctly (no mangled characters) | Round-trips a path with a space and a non-ASCII character |

Also worth checking while you're at it, since these don't need a specific
fixture:

- **Overlay clears after a drop**, both on acceptance (sheet opens with no
  stuck overlay behind it) and on rejection (banner shows, overlay itself is
  gone).
- **Disconnected daemon**: stop the daemon (or use Settings → Advanced to
  simulate it) and drag anything — the overlay should read "Connect to the
  container service to build," and the drop should be refused even if you
  release over the window.
- **Rapid re-reject**: drag `05-non-matching-name/README.md` twice in quick
  succession — the second rejection should reset the banner's ~3s dismiss
  timer rather than having the first timer cut the second message off early.
- **Sidebar drop**: drag `01-canonical-dockerfile/Dockerfile` directly onto
  the sidebar (not the list/detail area) — it should work exactly like
  dropping anywhere else in the window.

## A note on the symlinks (06–08)

`git` tracks symlinks natively (mode `120000`) and restores them as real
symbolic links on checkout — no setup needed after `git clone`, on macOS or
Linux. `08`'s symlink is intentionally broken (points at a target that
doesn't exist); that's the fixture, not a mistake.
