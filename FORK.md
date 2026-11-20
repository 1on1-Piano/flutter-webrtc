# 1on1 fork of flutter-webrtc

This repository is a fork of
[flutter-webrtc/flutter-webrtc](https://github.com/flutter-webrtc/flutter-webrtc)
used by the 1on1 app. It is upstream's released code plus a few small commits of
our own. Everything else (code, license, issues) belongs to upstream.

## What the fork changes, and why

On recent Android phones and tablets, the system applies voice isolation and
other voice processing to call audio. That suppresses the piano, so the far end
of a lesson cannot hear it. Our commits make the plugin's Android audio capture
avoid system voice isolation by default, behind a switch the app can change
later. iOS, macOS, web, and desktop code is unchanged.

The fork also adds the sync tooling (`tool/1on1/`, this file, and the
`1on1-sync-upstream` workflow) and removes upstream's
`.github/workflows/publish.yaml`. That workflow publishes to pub.dev on any tag
matching `v[0-9]+.[0-9]+.[0-9]+*`, which includes our `v<version>-1on1.<n>`
release tags. The fork is never published. The first release tag,
`v1.3.0-1on1.1`, predates this removal, so push it before Actions is enabled on
the fork, or that push starts a (failing) publish run. "Sync by hand" below
covers keeping the workflow deleted when upstream changes it.

The authoritative list of our changes is the commit history. Every commit of
ours has a subject starting with `[1on1] `:

```sh
base=$(cat tool/1on1/UPSTREAM_BASE)
git log --oneline --no-merges --ancestry-path "$base..1on1/main"   # our commits
git diff "$base" 1on1/main                                          # the whole fork delta
```

## Branches, tags, and versions

| Name | What it is |
|---|---|
| `upstream` remote | `https://github.com/flutter-webrtc/flutter-webrtc` |
| `1on1/main` | The fork's default branch: an upstream release tag plus our `[1on1]` commits. Never rewritten or force-pushed. |
| `1on1/sync-<tag>` | A proposed move of `1on1/main` onto upstream `<tag>`, for review. |
| `tool/1on1/UPSTREAM_BASE` | The upstream tag `1on1/main` is currently built on, for example `v1.3.0`. |
| `v<upstream>-1on1.<n>` | Our release tags, for example `v1.3.0-1on1.1`. The app pins one of these. |

The `version:` in `pubspec.yaml` is the upstream version plus `+1on1.<n>`, for
example `1.3.0+1on1.1`. If the upstream version already has build metadata, we
append `.1on1.<n>` instead (`1.6.2+hotfix.4.1on1.1`). Build metadata keeps the
version equal in precedence to upstream's, so packages that require
`flutter_webrtc ^1.3.0` still accept the fork. `publish_to: none` stops anyone
from publishing the fork to pub.dev.

Upstream tags its releases `vX.Y.Z`, with hotfixes as `vX.Y.Z+hotfix.N`. A few
tags lack the `v` (for example `1.6.2+hotfix.2`). The sync treats a tag as a
release only if pub.dev has the matching version, and orders versions as pub.dev
does (`1.6.2` < `1.6.2+hotfix.1` < `1.6.3`).

### Commit rules

- Every commit on `1on1/main` after the upstream base starts with `[1on1] `.
  The sync refuses to run if one does not.
- Keep each change small and in its own commit, so replays conflict rarely and
  clearly.
- Commits that only change the `version:` or `publish_to:` lines of
  `pubspec.yaml` or `tool/1on1/UPSTREAM_BASE` are bookkeeping. Name them
  `[1on1] release: <version>` or `[1on1] sync: ...`. A sync drops them and
  writes fresh ones, so never mix other changes into them.

## How a sync works

`tool/1on1/sync_upstream.sh` moves the fork onto a newer upstream release:

1. It lists upstream's tags (`git ls-remote`) and picks the newest stable
   release newer than `UPSTREAM_BASE` that is also on pub.dev, or the tag you
   pass with `--tag`.
2. It creates `1on1/sync-<tag>` from that tag and cherry-picks our `[1on1]`
   commits onto it, skipping bookkeeping commits and commits upstream already
   contains. That includes commits that reached `1on1/main` without building
   on the current base, for example ones pushed while a sync PR was open; the
   plan marks them "landed off the ... line".
3. It adds a `[1on1] sync:` commit that sets the fork version and
   `UPSTREAM_BASE`, then records the old `1on1/main` as a second parent with
   `git merge -s ours`. That merge takes none of the old content; it only makes
   the sync branch a descendant of `1on1/main`, so `1on1/main` can move to it
   without a force push, and every old release tag stays reachable.
4. It runs `flutter pub get`, `flutter analyze`, and `flutter build apk --debug`
   in `example/`.

The sync never changes `1on1/main` itself. You review the sync branch and land
it.

## Sync by hand

You need git, jq, curl, and Flutter. Android builds also need Java 17 and the
Android SDK; without them, add `--skip-build`.

```sh
git remote add upstream https://github.com/flutter-webrtc/flutter-webrtc.git   # once
git switch 1on1/main && git pull
tool/1on1/sync_upstream.sh --dry-run          # what would happen, changes nothing
tool/1on1/sync_upstream.sh                    # newest release
tool/1on1/sync_upstream.sh --tag v1.6.3       # or a specific one
```

Set `FLUTTER=/path/to/flutter` if Flutter is not on your PATH. Run
`tool/1on1/sync_upstream.sh --help` for every option.

**If a commit conflicts,** the script stops on the sync branch, lists the
conflicting files, and exits with code 3. Then:

```sh
# edit the files, then
git add <files>
git cherry-pick --continue        # repeat for further conflicts
bash "$(git rev-parse --git-path 1on1-sync)/sync_upstream.sh" --continue
```

A modify/delete or rename/delete conflict on a workflow file (`git status`
shows `UD`) means upstream changed a workflow our commits delete, such as the
pub.dev publish workflow. Keep it deleted: run `git rm <the path git lists>`,
not `git add`, which would bring the workflow back.

Use `--abort` the same way to give up: it returns you to your previous branch and
deletes the sync branch. (The script runs from a copy in `.git/`, because the
replay may not have restored `tool/1on1/` yet.)

**If the checks fail,** the sync branch is kept. Fix the problem with a new
`[1on1]` commit on it and run the checks again by hand: `flutter pub get`,
`flutter analyze`, and `flutter build apk --debug` in `example/`.

**Before landing a sync,** check that no workflow on the branch would run when
we push a release tag. Upstream may rename its publish workflow or add a new
one, and that replays without a conflict. List the workflows upstream added or
changed, and read the `on:` block of each:

```sh
git diff --name-status <old base tag> <new tag> -- .github/workflows/
git grep -n -E -A8 '^on:' 1on1/sync-<tag> -- .github/workflows/   # every on: block
```

A workflow runs on our tags if its `on:` (block or one-line form such as
`on: [push, create]`) has `tags:`, `tags-ignore:`, `create`, or `release`, or a
`push` with no `branches:` filter. If one does, delete that file in a new
`[1on1] ci:` commit on the sync branch.

**Landing a sync.** Push the branch (`git push origin 1on1/sync-<tag>`, or pass
`--push` to the script) and open a PR into `1on1/main`. Merge it with
**Create a merge commit**, or fast-forward from a checkout:
`git push origin 1on1/sync-<tag>:1on1/main`. Never squash or rebase-merge a sync
PR: that drops the history the next sync relies on, and the script will refuse
to run.

## Weekly sync in CI

`.github/workflows/1on1-sync-upstream.yml` runs every Monday and on demand
(Actions > 1on1 sync upstream > Run workflow, optionally with a tag). It has
two jobs:

1. **Replay and check**, with a read-only token. It does a dry run and stops
   if there is no new release, or if `1on1/sync-<tag>` already exists on the
   fork. Otherwise it replays and runs the checks with the Flutter version the
   app uses, and saves the result and the sync branch (as a git bundle) in the
   run's `1on1-sync` artifact. This job runs upstream's new code (pub packages,
   Gradle), so it gets no write access.
2. **Open a PR or issue**, with write access but none of upstream's code. It
   pushes `1on1/sync-<tag>` from the bundle and opens a PR into `1on1/main`, or
   opens an issue on a conflict, a failed check, or a refused push or PR. A
   re-run comments on the open issue rather than opening a new one.

Repository settings it needs:

- Actions enabled on the fork. GitHub disables workflows in a new fork until
  you enable them on the Actions tab.
- `1on1/main` as the default branch. Scheduled workflows run only from the
  default branch.
- "Allow GitHub Actions to create and approve pull requests" turned on, for
  the PR step.

Before merging a sync that CI proposed, run the same "Before landing a sync"
check as for a manual sync.

**Expect the push to be refused.** GitHub refuses pushes made with the
workflow token (`GITHUB_TOKEN`) that add or change files under
`.github/workflows/`, and a sync branch always does: it re-creates this
workflow on top of the new upstream tag. So, with only `GITHUB_TOKEN`, a
successful sync ends in a "branch push refused" issue, not a PR. The issue
gives the commands to push the exact branch the run tested from its artifact:

```sh
gh run download <run-id> --name 1on1-sync --dir /tmp/1on1-sync
git fetch /tmp/1on1-sync/sync.bundle 'refs/heads/1on1/sync-<tag>:refs/heads/1on1/sync-<tag>'
git push origin 1on1/sync-<tag>
```

Then open the PR with the text from the issue. To let CI open the PR itself,
the push needs a credential with workflow write access, such as a GitHub App
token. That is a separate decision.

GitHub also pauses scheduled workflows in a public repository after 60 days
without activity. Re-enable it on the Actions tab if that happens.

## Release a new `-1on1.N` tag

After a sync lands, tag the merged `1on1/main` with the tag the sync printed
(and wrote in the PR):

```sh
git switch 1on1/main && git pull
git tag -a v1.6.3-1on1.1 -m "flutter_webrtc 1.6.3+1on1.1" 1on1/main
git push origin v1.6.3-1on1.1
```

To release our own change without an upstream sync, add the `[1on1]` commit,
then bump `<n>` in its own commit, and tag that:

```sh
# pubspec.yaml: version: 1.6.3+1on1.1  ->  1.6.3+1on1.2
git commit -am "[1on1] release: 1.6.3+1on1.2"
git tag -a v1.6.3-1on1.2 -m "flutter_webrtc 1.6.3+1on1.2" 1on1/main
git push origin 1on1/main v1.6.3-1on1.2
```

Never move or delete a pushed release tag: app builds pin them.

## Point the app at a new release

The app depends on the fork through a git dependency in `app/pubspec.yaml`:

```yaml
flutter_webrtc:
  git:
    url: https://github.com/1on1-Piano/flutter-webrtc.git
    ref: v1.6.3-1on1.1
```

To upgrade, change `ref:` to the new tag, then run `flutter pub get` (which
updates the `resolved-ref` in `pubspec.lock`), `flutter analyze`, and the app's
tests and Android build. Check that `dart_webrtc` and `webrtc_interface` still
satisfy the new release's constraints. Commit `pubspec.yaml` and `pubspec.lock`
together.
