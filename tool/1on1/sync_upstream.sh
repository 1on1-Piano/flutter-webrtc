#!/usr/bin/env bash
#
# Moves the 1on1 fork of flutter-webrtc onto a newer upstream release: replays
# the fork's "[1on1] " commits onto the upstream tag in a new 1on1/sync-<tag>
# branch, records the new base and fork version, and runs the Flutter checks.
# FORK.md explains the branch, tag, and version scheme. Run with --help.
#
# Written for bash 3.2 (macOS) as well as bash 5 (Ubuntu): no associative
# arrays, no mapfile, and lists are newline-separated strings, not arrays.

set -euo pipefail

PREFIX='[1on1] '
nl='
'
BASE_FILE='tool/1on1/UPSTREAM_BASE'
PUBDEV_API='https://pub.dev/api/packages/flutter_webrtc'

upstream_remote=upstream
push_remote=origin
main_branch=1on1/main
target=''
mode=sync
dry_run=0
push=0
skip_build=0
cli_skip_build=0
pubdev_check=1
skip_if_proposed=0
status_file=''
flutter_bin=${FLUTTER:-flutter}

self_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
self="$self_dir/$(basename "${BASH_SOURCE[0]}")"

# Fields written to --status-file (JSON) for CI.
st_base='' st_target='' st_branch='' st_version='' st_release_tag=''
st_replayed='' st_skipped='' st_conflicts='' st_failed_commit='' st_message=''
st_report='' st_prediction='' st_note=''

usage() {
  cat <<'EOF'
Usage: tool/1on1/sync_upstream.sh [options]
       tool/1on1/sync_upstream.sh --continue | --abort

Replays the fork's [1on1] commits from 1on1/main onto the newest stable
upstream release newer than tool/1on1/UPSTREAM_BASE, in a new branch
1on1/sync-<tag>. Never touches 1on1/main and never force-pushes.

Options:
  --tag <tag>          Target this upstream tag instead of the newest release.
  --dry-run            Show the plan (and predict conflicts if the target tag
                       is already fetched); change no refs or files.
  --push               Push the new sync branch to the push remote (no force).
  --remote <name>      Push remote (default: origin).
  --upstream <name>    Upstream remote (default: upstream).
  --main <rev>         Fork branch to replay from (default: 1on1/main).
  --skip-build         Skip `flutter build apk --debug` in example/.
  --no-pubdev-check    Don't require the release to be published on pub.dev.
  --skip-if-proposed   Exit 0 if the sync branch already exists on the push
                       remote (for scheduled CI).
  --status-file <path> Write the outcome as JSON (for CI).
  --continue           Finish a sync after resolving a replay conflict.
  --abort              Abandon a sync in progress and delete its branch.
  -h, --help           Show this help.

Environment:
  FLUTTER              Flutter executable (default: flutter on PATH).

Exit codes: 0 synced, up to date, already proposed, or dry run; 1 error;
2 usage; 3 replay conflict; 4 checks failed; 5 push failed.
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'sync_upstream: warning: %s\n' "$*" >&2; }

write_status() {
  [ -n "$status_file" ] || return 0
  jq -n \
    --arg status "$1" --arg base "$st_base" --arg target "$st_target" \
    --arg branch "$st_branch" --arg fork_version "$st_version" \
    --arg release_tag "$st_release_tag" --arg failed_commit "$st_failed_commit" \
    --arg message "$st_message" --arg report "$st_report" \
    --arg replayed "$st_replayed" --arg skipped "$st_skipped" \
    --arg conflicts "$st_conflicts" --arg prediction "$st_prediction" \
    'def lines: split("\n") | map(select(length > 0));
     {status: $status, base: $base, target: $target, branch: $branch,
      fork_version: $fork_version, release_tag: $release_tag,
      failed_commit: $failed_commit, message: $message, report: $report,
      prediction: $prediction,
      replayed: ($replayed | lines), skipped: ($skipped | lines),
      conflicts: ($conflicts | lines)}' >"$status_file"
}

# die <message> [exit code] [status]
die() {
  printf 'sync_upstream: error: %s\n' "$1" >&2
  st_message=$1
  write_status "${3:-error}"
  exit "${2:-1}"
}

# Prints the stable upstream release tags newer than the version key $1
# ("MAJOR MINOR PATCH HOTFIX"), newest first. Upstream tags are mostly
# "v1.6.3" but some lack the "v" ("1.6.2+hotfix.2"); hotfix builds order after
# their base version, as on pub.dev. If both spellings exist, "v" wins.
newer_release_tags() {
  local refs
  refs=$(git ls-remote --tags --refs "$upstream_remote") || return 1
  printf '%s\n' "$refs" | awk '
    { t = $2; sub(/^refs\/tags\//, "", t) }
    t ~ /^v?[0-9]+\.[0-9]+\.[0-9]+(\+hotfix\.[0-9]+)?$/ {
      s = t; sub(/^v/, "", s); n = split(s, p, /[.+]/)
      printf "%d %d %d %d %d %s\n", p[1], p[2], p[3], (n == 5 ? p[5] : 0), (t ~ /^v/), t
    }' | sort -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5nr | awk -v base="$1" '
    BEGIN { split(base, b, " ") }
    {
      newer = 0
      for (i = 1; i <= 4; i++) {
        if ($i + 0 > b[i] + 0) { newer = 1; break }
        if ($i + 0 < b[i] + 0) break
      }
      if (!newer) next
      k = $1 " " $2 " " $3 " " $4
      if (k in seen) next
      seen[k] = 1
      print $6
    }'
}

# Prints "MAJOR MINOR PATCH HOTFIX" for a stable release tag, or nothing.
version_key() {
  printf '%s\n' "$1" | awk '
    /^v?[0-9]+\.[0-9]+\.[0-9]+(\+hotfix\.[0-9]+)?$/ {
      s = $0; sub(/^v/, "", s); n = split(s, p, /[.+]/)
      printf "%d %d %d %d\n", p[1], p[2], p[3], (n == 5 ? p[5] : 0)
    }'
}

key_newer() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, " "); split(b, y, " ")
    for (i = 1; i <= 4; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 1
  }'
}

pubdev_versions() {
  local json
  json=$(curl -fsSL --max-time 30 "$PUBDEV_API") || return 1
  printf '%s' "$json" | jq -r '.versions[].version'
}

local_commit() {
  git rev-parse -q --verify "$1^{commit}" 2>/dev/null || true
}

fetch_tag() {
  [ -n "$(local_commit "refs/tags/$1")" ] && return 0
  say "Fetching upstream tag $1"
  git fetch -q --no-tags "$upstream_remote" "refs/tags/$1:refs/tags/$1" ||
    die "could not fetch tag $1 from remote '$upstream_remote'"
}

remote_exists() {
  git remote get-url "$1" >/dev/null 2>&1
}

# The next -1on1.N number for upstream version $1, from local and push-remote tags.
next_release_number() {
  local tags
  tags=$(git tag -l "v$1-1on1.*")
  if remote_exists "$push_remote"; then
    tags="$tags
$(git ls-remote --tags --refs "$push_remote" 2>/dev/null | sed 's#.*refs/tags/##' || true)"
  fi
  printf '%s\n' "$tags" | awk -v p="v$1-1on1." '
    index($0, p) == 1 { s = substr($0, length(p) + 1); if (s ~ /^[0-9]+$/ && s + 0 > m) m = s + 0 }
    END { print m + 1 }'
}

fork_version_for() { # <upstream version> <n>
  case $1 in
  *+*) printf '%s.1on1.%s\n' "$1" "$2" ;;
  *) printf '%s+1on1.%s\n' "$1" "$2" ;;
  esac
}

set_pubspec_version() {
  local add_publish_to=1
  grep -q '^publish_to:' pubspec.yaml && add_publish_to=0
  awk -v v="$1" -v add="$add_publish_to" '
    /^version:/ && !done { print "version: " v; if (add) print "publish_to: none"; done = 1; next }
    { print }
    END { if (!done) exit 3 }' pubspec.yaml >pubspec.yaml.1on1-tmp ||
    { rm -f pubspec.yaml.1on1-tmp; die "pubspec.yaml has no version: line"; }
  mv pubspec.yaml.1on1-tmp pubspec.yaml
}

ensure_clean() {
  git diff --quiet && git diff --cached --quiet ||
    die "the working tree has uncommitted changes; commit or stash them first"
  local d
  for d in CHERRY_PICK_HEAD MERGE_HEAD REVERT_HEAD sequencer rebase-merge rebase-apply; do
    [ ! -e "$(git rev-parse --git-path "$d")" ] ||
      die "a git operation is in progress ($d); finish or abort it first"
  done
}

# True while a cherry-pick sequence is unfinished. CHERRY_PICK_HEAD alone is
# not enough: `git commit` on a conflict removes it but leaves the rest of the
# sequence in .git/sequencer.
replay_in_progress() {
  [ -e "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ] ||
    [ -e "$(git rev-parse --git-path sequencer)" ]
}

save_state() {
  mkdir -p "$state_dir"
  cp "$self" "$state_dir/sync_upstream.sh"
  {
    printf 'target=%s\n' "$target"
    printf 'base=%s\n' "$base"
    printf 'branch=%s\n' "$branch"
    printf 'main_branch=%s\n' "$main_branch"
    printf 'main_sha=%s\n' "$main_sha"
    printf 'orig_ref=%s\n' "$orig_ref"
    printf 'skip_build=%s\n' "$skip_build"
    printf 'push=%s\n' "$push"
    printf 'push_remote=%s\n' "$push_remote"
    printf 'upstream_remote=%s\n' "$upstream_remote"
  } >"$state_dir/state"
  printf '%s' "$st_replayed" >"$state_dir/replayed"
  printf '%s' "$st_skipped" >"$state_dir/skipped"
}

load_state() {
  [ -f "$state_dir/state" ] || die "no sync in progress (no $state_dir/state)"
  local k v
  while IFS='=' read -r k v; do
    case $k in
    target) target=$v ;;
    base) base=$v ;;
    branch) branch=$v ;;
    main_branch) main_branch=$v ;;
    main_sha) main_sha=$v ;;
    orig_ref) orig_ref=$v ;;
    skip_build) skip_build=$v ;;
    push) push=$v ;;
    push_remote) push_remote=$v ;;
    upstream_remote) upstream_remote=$v ;;
    esac
  done <"$state_dir/state"
  [ "$cli_skip_build" = 0 ] || skip_build=1
  st_replayed=$(cat "$state_dir/replayed")
  st_skipped=$(cat "$state_dir/skipped")
  st_base=$base st_target=$target st_branch=$branch
  target_commit=$(local_commit "refs/tags/$target")
  [ -n "$target_commit" ] || die "tag $target is missing locally"
}

# Sets base, base_key, main_sha, and the replay plan (replay, st_replayed,
# st_skipped) for main_branch. target_commit may be empty (dry run, unfetched).
plan_replay() {
  # equiv, bad, and path_patch_ids are read by classify_commit.
  local base_raw base_commit c m on_path excl all equiv='' bad='' path_patch_ids=''
  main_sha=$(local_commit "$main_branch")
  [ -n "$main_sha" ] || die "branch $main_branch not found"
  base_raw=$(git show "$main_sha:$BASE_FILE" 2>/dev/null) ||
    die "$main_branch has no $BASE_FILE recording its upstream base tag"
  base=$(printf '%s' "$base_raw" | tr -d '[:space:]')
  base_key=$(version_key "$base")
  [ -n "$base_key" ] || die "$BASE_FILE holds '$base', which is not a stable upstream release tag"
  st_base=$base
  base_commit=$(local_commit "refs/tags/$base")
  if [ -z "$base_commit" ]; then
    [ "$dry_run" = 0 ] || die "base tag $base is not fetched; run: git fetch $upstream_remote tag $base"
    fetch_tag "$base"
    base_commit=$(local_commit "refs/tags/$base")
  fi
  git merge-base --is-ancestor "$base_commit" "$main_sha" ||
    die "$BASE_FILE says $base, but $base is not an ancestor of $main_branch (was a sync squashed or rebased?)"

  if [ -n "$target_commit" ]; then
    equiv=$(git cherry "$target_commit" "$main_sha" "$base_commit")
  fi

  # Our commits since the last sync descend from the base tag.
  on_path=$(git rev-list --reverse --topo-order --no-merges --ancestry-path "$base_commit..$main_sha")
  # Commits that reached main without descending from the base (for example,
  # pushed while a sync PR was open, or a branch cut before the last sync) are
  # still in main's tree and must be replayed too. The old lines an earlier
  # sync already replayed hang off each sync's "keep history" merge as its
  # second parent, so exclude those.
  excl=''
  for m in $(git rev-list --merges --ancestry-path "$base_commit..$main_sha"); do
    case $(git log -1 --format=%s "$m") in
    "${PREFIX}sync: keep "*) excl="$excl ^$m^2" ;;
    esac
  done
  # shellcheck disable=SC2086 # $excl is a list of ^<commit> arguments
  all=$(git rev-list --reverse --topo-order --no-merges "$base_commit..$main_sha" $excl)
  if [ "$all" != "$on_path" ]; then
    path_patch_ids=$(git log --no-merges -p --ancestry-path "$base_commit..$main_sha" | git patch-id --stable | cut -d' ' -f1)
  fi

  # Replay in history order, so a commit never comes before one it builds on.
  replay='' st_replayed='' st_skipped=''
  for c in $all; do
    case "$nl$on_path$nl" in
    *"$nl$c$nl"*) classify_commit "$c" '' ;;
    *) classify_commit "$c" off-path ;;
    esac
  done
  [ -z "$bad" ] || die "commits on $main_branch since $base lack the '$PREFIX' prefix:$bad"
}

# Adds commit $1 to the replay plan or the skip list. $2 is "off-path" for a
# commit that does not descend from the base tag.
classify_commit() {
  local c=$1 subj short pid note=''
  subj=$(git log -1 --format=%s "$c")
  short=$(git rev-parse --short "$c")
  case $subj in
  "$PREFIX"*) ;;
  *)
    bad="$bad
  $short $subj"
    return 0
    ;;
  esac
  case $subj in
  "${PREFIX}sync: "* | "${PREFIX}release: "*)
    is_bookkeeping "$c" ||
      die "bookkeeping commit $short ('$subj') changes more than the pubspec version and $BASE_FILE; move the rest into its own [1on1] commit"
    ;;
  *)
    # A version bump made under another subject is bookkeeping too.
    if ! is_bookkeeping "$c"; then
      case "$nl$equiv$nl" in
      *"$nl- $c$nl"*)
        st_skipped="$st_skipped$short $subj (already in $target)
"
        return 0
        ;;
      esac
      if [ "$2" = off-path ]; then
        pid=$(git show "$c" | git patch-id --stable | cut -d' ' -f1)
        case "$nl$path_patch_ids$nl" in
        *"$nl$pid$nl"*)
          st_skipped="$st_skipped$short $subj (already re-applied on $main_branch)
"
          return 0
          ;;
        esac
        note=" (landed off the $base line; replayed)"
      fi
      replay="$replay $c"
      st_replayed="$st_replayed$short $subj$note
"
      return 0
    fi
    ;;
  esac
  st_skipped="$st_skipped$short $subj (bookkeeping, regenerated)
"
}

# True if commit $1 changes only the version: / publish_to: lines of
# pubspec.yaml and/or the base file. These are regenerated by every sync, so
# replaying them would only conflict.
is_bookkeeping() {
  local files lines
  files=$(git diff-tree --no-commit-id --name-only -r "$1")
  [ -n "$files" ] || return 1
  if printf '%s\n' "$files" | grep -vxF -e pubspec.yaml -e "$BASE_FILE" >/dev/null; then
    return 1
  fi
  lines=$(git diff-tree --no-commit-id -p -U0 "$1" -- pubspec.yaml | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' || true)
  [ -n "$lines" ] || return 0
  if printf '%s\n' "$lines" | grep -vE '^[+-](version|publish_to):' >/dev/null; then
    return 1
  fi
  return 0
}

choose_target() {
  local candidates published='' t
  if [ -n "$target" ]; then
    case $target in
    *[!A-Za-z0-9._+-]*) die "invalid tag name: $target" 2 ;;
    esac
    [ -n "$(version_key "$target")" ] || die "$target is not a stable upstream release tag (vX.Y.Z or X.Y.Z+hotfix.N)"
    key_newer "$(version_key "$target")" "$base_key" || die "$target is not newer than the fork's base $base"
    [ -n "$(git ls-remote --tags --refs "$upstream_remote" "refs/tags/$target")" ] ||
      die "tag $target not found on remote '$upstream_remote'"
    return 0
  fi
  candidates=$(newer_release_tags "$base_key") || die "could not list tags on remote '$upstream_remote'"
  if [ "$pubdev_check" = 1 ] && [ -n "$candidates" ]; then
    published=$(pubdev_versions) || die "pub.dev lookup failed; retry, or pass --no-pubdev-check"
  fi
  for t in $candidates; do
    if [ "$pubdev_check" = 1 ]; then
      case "$nl$published$nl" in
      *"$nl${t#v}$nl"*) ;;
      *)
        warn "upstream tag $t has no pub.dev release ${t#v}; skipping it"
        continue
        ;;
      esac
    fi
    target=$t
    return 0
  done
}

# Simulates the replay with `git merge-tree` (git >= 2.40). It writes only
# unreferenced objects, which git gc removes. Prints the outcome.
predict_replay() {
  local cur=$target_commit c out rc tree
  for c in $replay; do
    rc=0
    out=$(git merge-tree --write-tree --no-messages --name-only --merge-base="$c^" "$cur" "$c" 2>/dev/null) || rc=$?
    if [ "$rc" -gt 1 ]; then
      say "Conflict prediction unavailable (needs git 2.40 or newer)."
      st_prediction=unknown
      return 0
    fi
    if [ "$rc" = 1 ]; then
      say "Predicted conflict replaying $(git log -1 --format='%h %s' "$c"):"
      printf '%s\n' "$out" | sed -n '2,$s/^/  /p'
      st_prediction=conflict
      return 0
    fi
    tree=$(printf '%s\n' "$out" | sed -n 1p)
    cur=$(git commit-tree "$tree" -p "$cur" -m 'sync_upstream dry run')
  done
  say "Predicted: the replay applies cleanly."
  st_prediction=clean
}

print_plan() {
  say "Fork branch:    $main_branch ($(git rev-parse --short "$main_sha"))"
  say "Current base:   $base"
  say "Target:         $target"
  say "Sync branch:    $branch"
  say "Replay ($(printf '%s' "$st_replayed" | grep -c . || true) commits):"
  printf '%s' "$st_replayed" | sed 's/^/  /'
  if [ -n "$st_skipped" ]; then
    say "Skip:"
    printf '%s' "$st_skipped" | sed 's/^/  /'
  fi
}

report_conflict() {
  local failed subj
  failed=$(git rev-parse -q --verify CHERRY_PICK_HEAD 2>/dev/null || true)
  st_conflicts=$(git diff --name-only --diff-filter=U)
  if [ -n "$failed" ]; then
    subj=$(git log -1 --format='%h %s' "$failed")
    st_failed_commit=$subj
  else
    subj='(unknown commit)'
  fi
  say ""
  say "Replay stopped at $subj onto $target, on branch $branch."
  if [ -n "$st_conflicts" ]; then
    say "Conflicting files:"
    printf '%s\n' "$st_conflicts" | sed 's/^/  /'
  else
    say "No conflicting files: the commit is probably already in $target (skip it with: git cherry-pick --skip)."
  fi
  cat <<EOF

To resolve:
  1. Fix the files, then: git add <files> && git cherry-pick --continue
     (repeat for any further conflicts; git cherry-pick --skip drops a commit
     that upstream already contains).
  2. Then finish the sync:
       bash $state_dir/sync_upstream.sh --continue
To give up and return to $orig_ref:
       bash $state_dir/sync_upstream.sh --abort
EOF
  st_message="replay of $subj onto $target conflicts"
  st_report=$(
    printf 'Replaying the fork onto upstream `%s` stopped at `%s`.\n\n' "$target" "$subj"
    if [ -n "$st_conflicts" ]; then
      printf 'Conflicting files:\n\n'
      printf '%s\n' "$st_conflicts" | sed 's/^/- `/; s/$/`/'
    fi
    printf '\nResolve locally:\n\n```sh\ngit switch %s && git pull\ntool/1on1/sync_upstream.sh --tag %s\n' "$main_branch" "$target"
    printf '# fix files, git add, git cherry-pick --continue, then:\nbash "$(git rev-parse --git-path 1on1-sync)/sync_upstream.sh" --continue\n```\n'
  )
  write_status conflict
  exit 3
}

run_checks() {
  if ! command -v "$flutter_bin" >/dev/null 2>&1; then
    st_message="flutter not found; put it on PATH or set FLUTTER"
    return 1
  fi
  say "== flutter pub get"
  "$flutter_bin" pub get || { st_message="flutter pub get failed"; return 1; }
  say "== flutter analyze"
  "$flutter_bin" analyze || { st_message="flutter analyze failed"; return 1; }
  if [ "$skip_build" = 1 ]; then
    say "== flutter build apk --debug (skipped: --skip-build)"
  else
    say "== flutter build apk --debug (example/)"
    (cd example && "$flutter_bin" build apk --debug) || { st_message="flutter build apk --debug failed"; return 1; }
  fi
}

# The Flutter tool regenerates some tracked example/ files (plugin
# registrants); the tree was clean before the checks, so put them back.
restore_generated() {
  local changed
  changed=$(git diff --name-only)
  [ -n "$changed" ] || return 0
  say "Restoring tracked files the Flutter tool regenerated:"
  printf '%s\n' "$changed" | sed 's/^/  /'
  git checkout -q -- .
}

summarize() {
  local n_replayed checks
  n_replayed=$(printf '%s' "$st_replayed" | grep -c . || true)
  if [ "$skip_build" = 1 ]; then
    checks='flutter pub get, flutter analyze (APK build skipped)'
  else
    checks='flutter pub get, flutter analyze, flutter build apk --debug (example/)'
  fi
  st_report=$(
    printf 'Moves `%s` from upstream `%s` to `%s`: %s replayed `[1on1]` commits plus a sync commit that sets the fork version to `%s`.\n\n' \
      "$main_branch" "$base" "$target" "$n_replayed" "$st_version"
    printf 'Replayed:\n\n'
    printf '%s' "$st_replayed" | sed 's/^/- /'
    if [ -n "$st_skipped" ]; then
      printf '\nSkipped:\n\n'
      printf '%s' "$st_skipped" | sed 's/^/- /'
    fi
    printf '\nChecks passed: %s.\n\n' "$checks"
    [ -z "$st_note" ] || printf '**Note:** %s\n\n' "$st_note"
    printf 'Review the fork delta with `git diff %s %s`.\n\n' "$target" "$branch"
    printf 'Merge with **Create a merge commit** (or fast-forward `%s`). Squash or rebase merging breaks the next sync.\n\n' "$main_branch"
    printf 'After merging, the release tag (needs approval):\n\n```sh\ngit tag -a %s -m "flutter_webrtc %s" %s\ngit push %s %s\n```\n\n' \
      "$st_release_tag" "$st_version" "$main_branch" "$push_remote" "$st_release_tag"
    printf 'Then point the app'"'"'s `flutter_webrtc` git `ref:` at `%s`.\n' "$st_release_tag"
  )
  say ""
  say "Synced $main_branch onto upstream $target in branch $branch."
  say "  fork version: $st_version"
  say "  replayed:     $n_replayed commits"
  say "  review:       git log --oneline --no-merges $target..$branch; git diff $target $branch"
  if [ "$push" = 1 ]; then
    say "  pushed:       $push_remote/$branch"
  else
    say "  push:         git push $push_remote $branch   (then open a PR into $main_branch)"
  fi
  say "  land:         merge the PR with a merge commit, or: git push $push_remote $branch:$main_branch"
  say "  release:      git tag -a $st_release_tag -m \"flutter_webrtc $st_version\" $main_branch && git push $push_remote $st_release_tag"
}

finish() {
  local upstream_version n main_short checks_ok planned_n actual_n
  ! replay_in_progress ||
    die "the replay is still in progress; finish it (git cherry-pick --continue or --skip) first"
  [ "$(git symbolic-ref -q --short HEAD || true)" = "$branch" ] ||
    die "expected to be on branch $branch"
  git diff --quiet && git diff --cached --quiet ||
    die "the working tree has uncommitted changes"

  upstream_version=$(git show "$target_commit:pubspec.yaml" | awk '/^version:/ { print $2; exit }')
  [ -n "$upstream_version" ] || die "no version: in pubspec.yaml at $target"
  n=$(next_release_number "$upstream_version")
  st_version=$(fork_version_for "$upstream_version" "$n")
  st_release_tag="v$upstream_version-1on1.$n"
  main_short=$(git rev-parse --short "$main_sha")

  planned_n=$(printf '%s' "$st_replayed" | grep -c . || true)
  actual_n=$(git rev-list --count --no-merges "$target_commit..HEAD")
  if [ "$actual_n" != "$planned_n" ]; then
    warn "planned to replay $planned_n commits but $branch has $actual_n (skipped or added while resolving?)"
    st_note="Planned to replay $planned_n commits, but the branch has $actual_n on top of \`$target\`. Check that none was dropped by mistake."
  fi

  set_pubspec_version "$st_version"
  mkdir -p "$(dirname "$BASE_FILE")"
  printf '%s\n' "$target" >"$BASE_FILE"
  git add pubspec.yaml "$BASE_FILE"
  git commit -q -m "${PREFIX}sync: upstream $target ($st_version)" \
    -m "Replays the fork's commits from $main_branch ($main_short) onto upstream $target."
  # Record the old fork history as a parent without taking any of its content,
  # so the sync branch fast-forwards $main_branch (no force push) and the next
  # sync finds this replay with --ancestry-path.
  git merge -q -s ours --no-ff -m "${PREFIX}sync: keep $main_branch history ($main_short) after moving to $target" "$main_sha"
  rm -rf "$state_dir"

  checks_ok=1
  run_checks || checks_ok=0
  restore_generated
  if [ "$checks_ok" = 0 ]; then
    say "Checks failed on $branch: $st_message"
    say "The branch is kept. Fix it with a new [1on1] commit on $branch, re-run the checks by hand:"
    say "  flutter pub get && flutter analyze && (cd example && flutter build apk --debug)"
    say "then push it: git push $push_remote $branch"
    write_status checks-failed
    exit 4
  fi

  if [ "$push" = 1 ]; then
    git push "$push_remote" "refs/heads/$branch:refs/heads/$branch" || {
      st_message="git push of $branch to $push_remote failed (see the git output above)"
      summarize
      write_status push-failed
      die "$st_message" 5 push-failed
    }
  fi
  summarize
  write_status synced
}

do_sync() {
  local proposed
  ensure_clean
  plan_replay
  choose_target
  if [ -z "$target" ]; then
    say "Up to date: no stable upstream release newer than $base."
    st_message="no upstream release newer than $base"
    write_status up-to-date
    return 0
  fi
  st_target=$target
  branch="1on1/sync-$target"
  st_branch=$branch
  git check-ref-format --branch "$branch" >/dev/null || die "invalid branch name $branch"

  if [ "$skip_if_proposed" = 1 ] && remote_exists "$push_remote"; then
    proposed=$(git ls-remote --heads "$push_remote" "refs/heads/$branch") ||
      die "could not query remote '$push_remote'"
    if [ -n "$proposed" ]; then
      say "Already proposed: $push_remote has $branch."
      st_message="$branch already exists on $push_remote"
      write_status already-proposed
      return 0
    fi
  fi
  [ -z "$(local_commit "refs/heads/$branch")" ] ||
    die "branch $branch already exists locally; delete it (git branch -D $branch) to sync again"

  target_commit=$(local_commit "refs/tags/$target")
  if [ "$dry_run" = 1 ]; then
    if [ -n "$target_commit" ]; then
      plan_replay
    fi
    print_plan
    if [ -z "$target_commit" ]; then
      say "Conflict prediction skipped: tag $target is not fetched (git fetch $upstream_remote tag $target)."
      st_prediction=unknown
    else
      predict_replay
    fi
    say "Dry run: nothing changed."
    st_message="dry run"
    write_status dry-run
    return 0
  fi

  fetch_tag "$target"
  target_commit=$(local_commit "refs/tags/$target")
  plan_replay
  print_plan
  orig_ref=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
  save_state
  if ! git checkout -q -b "$branch" "$target_commit"; then
    rm -rf "$state_dir"
    die "could not check out $target as $branch (an untracked file in the way?)"
  fi
  if [ -n "$replay" ]; then
    # shellcheck disable=SC2086 # $replay is a list of commit IDs
    git cherry-pick $replay || report_conflict
  fi
  finish
}

do_continue() {
  load_state
  ! replay_in_progress ||
    die "the replay is still in progress; resolve, git add, and git cherry-pick --continue first"
  finish
}

do_abort() {
  load_state
  if replay_in_progress; then
    git cherry-pick --abort
  fi
  git checkout -q "$orig_ref"
  if [ -n "$(local_commit "refs/heads/$branch")" ]; then
    git branch -q -D "$branch"
  fi
  rm -rf "$state_dir"
  say "Aborted the sync to $target; back on $orig_ref and $branch deleted."
  st_message="aborted"
  write_status aborted
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
    --tag) [ $# -ge 2 ] || die "--tag needs a value" 2; target=$2; shift ;;
    --tag=*) target=${1#--tag=} ;;
    --dry-run) dry_run=1 ;;
    --push) push=1 ;;
    --remote) [ $# -ge 2 ] || die "--remote needs a value" 2; push_remote=$2; shift ;;
    --upstream) [ $# -ge 2 ] || die "--upstream needs a value" 2; upstream_remote=$2; shift ;;
    --main) [ $# -ge 2 ] || die "--main needs a value" 2; main_branch=$2; shift ;;
    --skip-build) skip_build=1 cli_skip_build=1 ;;
    --no-pubdev-check) pubdev_check=0 ;;
    --skip-if-proposed) skip_if_proposed=1 ;;
    --status-file)
      [ $# -ge 2 ] || die "--status-file needs a value" 2
      case $2 in /*) status_file=$2 ;; *) status_file="$PWD/$2" ;; esac
      shift
      ;;
    --continue) mode=continue ;;
    --abort) mode=abort ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" 2 ;;
    esac
    shift
  done
}

main() {
  local top
  parse_args "$@"
  for tool in git jq curl awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  cd "$top"
  state_dir=$(git rev-parse --git-path 1on1-sync)
  case $state_dir in /*) ;; *) state_dir="$top/$state_dir" ;; esac
  target_commit=''

  case $mode in
  continue) do_continue ;;
  abort) do_abort ;;
  *)
    [ ! -e "$state_dir/state" ] ||
      die "a sync is already in progress; run with --continue or --abort"
    do_sync
    ;;
  esac
}

# Everything runs from main, so bash has parsed the whole file before the
# checkout below replaces it in the working tree.
main "$@"
exit $?
