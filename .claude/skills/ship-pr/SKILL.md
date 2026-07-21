---
name: ship-pr
description: Push the current branch, open a PR, watch CI, fix failures until green, merge, then clean up (delete local branch, resync main). Use when the user asks to send/open/ship a PR, check PR or CI status, fix a failing check, or merge and clean up after one.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Bash
  - Grep
---

# /ship-pr

Drives a feature branch from "ready to send" through merged-and-cleaned-up.
`gh` does the mechanical work; this skill supplies the judgment: which
checks actually gate the merge, how to tell a real CI failure from a known
flake, and when to stop and ask before an irreversible step.

Arguments: `$ARGUMENTS` (optional — a PR number, if resuming a PR that's
already open rather than creating a new one).

## 0. Orient

- `git status --short` and `git branch --show-current` — refuse on `main`
  (nothing to PR) and don't push a dirty tree silently; confirm with the
  user whether uncommitted changes should be committed first.
- `git log origin/main..HEAD --oneline` — confirm there are commits to
  ship. If empty, stop and say so.
- `gh pr view --json number,state 2>/dev/null` — if a PR already exists for
  this branch (or `$ARGUMENTS` gave a number), resume at step 2 instead of
  creating a new one.

## 1. Push and open the PR

- `git push -u origin <branch>` (first push) or `git push` (subsequent).
- `gh pr create --fill` or with explicit `--title`/`--body`.

**This repo is squash-merge-only** (`allow_squash_merge: true`,
`allow_merge_commit: false`, `allow_rebase_merge: false` — verified via
`gh api repos/<owner>/<repo>`), so the PR title becomes the final commit
subject. Write it to match the commit convention: imperative mood,
conventional-commit prefix (`feat:`/`fix:`/`chore:`/`docs:`), no
`Co-Authored-By` trailer — same as any commit in this repo.

## 2. Watch CI

`gh pr checks <number> --watch` blocks until all checks finish. This
project's `ci.yml` has four jobs to know apart:

- **ShellCheck**, **SwiftLint**, and the **"Unit tests"** leg of the `test`
  matrix are the real gate — `ci.yml` calls "Unit tests" the merge gate in
  its own comments.
- **"UI tests (mock mode)"** is explicitly advisory: hosted-runner XCUITest
  is known-flaky on timing/focus (per `ci.yml`'s comment and this repo's
  `ui-testing` skill's deflaking lore). A single red run here isn't proof
  of a real bug.

Branch protection is **not actually configured** on this repo (confirmed:
`gh api repos/<owner>/<repo>/branches/main/protection` 404s) despite the
aspirational comment in `ci.yml` — so GitHub will let you merge with
anything red. Don't. Treat ShellCheck/SwiftLint/Unit-tests-red as a hard
stop regardless of what the merge button allows.

## 3. Diagnose and fix a failure

- `gh pr checks <number>` to see which job failed; `gh run list --branch
  <branch>` for the run id; `gh run view <run-id> --log-failed` to pull
  just the failing steps (much smaller than the full log).
- If it's **UI tests (mock mode)** failing and nothing else: rerun once
  (`gh run rerun <run-id> --failed`) before investigating — it may be a
  known flake. If it fails the same way twice, stop waving it off and
  treat it as real (see this repo's `ui-testing`/`e2e-testing` skills).
- If it's **ShellCheck**, **SwiftLint**, or **Unit tests**: reproduce
  locally first —
  - `shellcheck scripts/*.sh design/icon/build.sh`
  - `swiftlint lint --strict`
  - the specific failing test via Xcode/`xcodebuild test -only-testing:...`
- Fix the root cause. Follow this repo's own rules while doing it: comments
  explain *why* not *what* (`CLAUDE.md` "Comments"), lint findings get
  fixed rather than suppressed (a `swiftlint:disable` needs a one-line
  justification and the narrowest scope, per `CLAUDE.md` "Linting"), and
  `Core/` logic changes need a corresponding `BerthlyTests` case
  (`CLAUDE.md` "Testing").
- Commit the fix: imperative mood, conventional prefix, no
  `Co-Authored-By` trailer. Push a new commit — don't amend/force-push a
  commit that's already part of the open PR's history.
- Loop back to step 2.

## 4. Merge once green

Confirm ShellCheck, SwiftLint, and Unit tests are green, and UI tests
(mock mode) is either green or a confirmed one-off flake (step 3).

**Stop and confirm with the user before merging** — it's a real,
publicly-visible, hard-to-reverse action, same bar as this repo's
`release-berthly` skill applies to publishing a release.

```sh
gh pr merge <number> --squash --delete-branch
```

`--delete-branch` deletes the remote branch (the repo also has
`delete_branch_on_merge: true`, so this is belt-and-suspenders) *and* the
local branch, switching the local checkout to `main` in the same step.

## 5. Resync main

- `git branch --show-current` — should already read `main` from step 4;
  `git checkout main` if not.
- `git branch -d <old-branch>` — defensive, in case it's somehow still
  present.
- `git fetch origin main`
- `git rebase origin/main` — picks up the just-merged squash commit (and
  anything else merged meanwhile) onto local `main`.

## Don'ts

- Don't merge with ShellCheck/SwiftLint/Unit-tests red just because GitHub
  doesn't block it — branch protection isn't configured, but the bar in
  `CLAUDE.md` still applies.
- Don't force-push over an open PR's history to "fix" a failure — add a
  new commit instead.
- Don't treat one red "UI tests (mock mode)" run as a confirmed bug —
  retry once, escalate only on a repeat with the same failure signature.
- Don't run `gh pr merge` without the user's explicit go-ahead.
