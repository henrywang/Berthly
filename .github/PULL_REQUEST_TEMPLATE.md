## What & why

<!-- What does this PR change, and what problem does it solve? -->

## Screenshots

<!-- For UI changes, before/after screenshots. Delete this section otherwise. -->

## Checklist

- [ ] Changes to `Berthly/Core/` have corresponding tests in `BerthlyTests` (Swift Testing)
- [ ] `xcodebuild test -scheme Berthly -destination 'platform=macOS'` passes locally
- [ ] The build is warning-free
- [ ] Commit messages use imperative mood with a conventional prefix (`feat:`, `fix:`, …)

## Daemon / integration coverage

Does this touch real-daemon paths CI can't run (`LiveContainerService`,
daemon lifecycle, `TerminalSession`/PTY, build/log streaming)?

- [ ] No — not applicable
- [ ] Yes, and I ran the full test suite locally against a running `container` daemon
