#!/usr/bin/env bash
# sync-mole.sh — bring new upstream Mole commits into nixit.
#
# nixit keeps Mole's Go tools (cmd/, internal/, go.mod, go.sum) and merges
# their upstream changes. Everything else (the shell commands, docs, CI) was
# rewritten for Arch, so upstream changes there are only listed for review.
#
# For each Go file Mole changed, the script runs a three-way merge in which
# both Mole versions (old and new) first get the nixit rename (module path,
# command names, cache dirs, darwin -> linux build tags). Renaming therefore
# never shows up as a change, and only real upstream edits are merged into
# nixit's Linux code. The result is committed on a new sync/mole-<date> branch
# as a merge with Mole's commit as second parent, so Mole's history stays
# linked and the next run starts where this one ended. Nothing is pushed and
# main is never touched.
#
# Usage:
#   scripts/sync-mole.sh            fetch Mole and merge new commits
#   scripts/sync-mole.sh --check    only list what is new
#   scripts/sync-mole.sh --finish   commit after resolving conflicts by hand
#   options: --upstream-ref REF (default upstream/main), --base BRANCH (default main)

set -euo pipefail

UPSTREAM_URL="https://github.com/tw93/Mole.git"
UPSTREAM_REF="upstream/main"
BASE_BRANCH="main"
MODE=sync
# Paths whose upstream changes are merged. Everything else is nixit's own.
KEEP_PATHS=(cmd internal go.mod go.sum)

while (($#)); do
    case "$1" in
        --check) MODE=check ;;
        --finish) MODE=finish ;;
        --upstream-ref)
            UPSTREAM_REF="$2"
            shift
            ;;
        --base)
            BASE_BRANCH="$2"
            shift
            ;;
        -h | --help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ -t 1 ]]; then
    B=$'\033[1m' G=$'\033[0;32m' Y=$'\033[0;33m' R=$'\033[0;31m' D=$'\033[0;38;5;244m' N=$'\033[0m'
else
    B='' G='' Y='' R='' D='' N=''
fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
note() { printf '%s%s%s\n' "$D" "$*" "$N"; }
fail() {
    printf '%sError:%s %s\n' "$R" "$N" "$*" >&2
    exit 1
}

ROOT="$(git rev-parse --show-toplevel 2> /dev/null)" || fail "Run this inside the nixit repository."
cd "$ROOT"
STATE_FILE="$(git rev-parse --git-path nixit-mole-sync)"

# rename_for_nixit: stdin -> stdout. The same rename nixit's own history applied.
rename_for_nixit() {
    sed -E \
        -e 's#^//go:build darwin$#//go:build linux#' \
        -e 's#github.com/tw93/mole#github.com/Cosmin-T/nixit#g' \
        -e 's/\bmo (status|analyze|uninstall|clean|purge)\b/nixit \1/g' \
        -e 's/"\.cache", "mole"/".cache", "nixit"/g' -e 's/"\.config", "mole"/".config", "nixit"/g' \
        -e 's#~/\.cache/mole#~/.cache/nixit#g' -e 's#~/\.config/mole#~/.config/nixit#g' \
        -e 's/MOLE_/NIXIT_/g' -e "s/\bMole's\b/nixit's/g" -e 's/\bMole\b/nixit/g' \
        -e 's/moleCacheRoot/nixitCacheRoot/g' -e 's/getMoleCacheRoot/getNixitCacheRoot/g'
}

# run_checks -> 0 when nixit builds and every test passes.
run_checks() {
    local log
    log=$(mktemp)
    if { go build ./... && go vet ./... && go test ./... && bash tests/run.sh; } > "$log" 2>&1; then
        rm -f "$log"
        make build > /dev/null 2>&1 || true
        return 0
    fi
    tail -n 40 "$log" >&2
    rm -f "$log"
    return 1
}

# commit_sync UPSTREAM_SHA MESSAGE: commit the index as a merge of HEAD and
# Mole's commit, keeping exactly nixit's merged tree.
commit_sync() {
    local upstream="$1" message="$2" tree commit
    tree=$(git write-tree)
    commit=$(git commit-tree "$tree" -p HEAD -p "$upstream" -m "$message")
    git update-ref -m "sync-mole: $message" HEAD "$commit"
}

finish_message() {
    printf '\n%sSynced.%s Branch %s now contains Mole %s; build and tests pass.\n' "$G" "$N" "$1" "$(git rev-parse --short "$2")"
    cat << EOF

Next:
  git diff $BASE_BRANCH --stat          # review what changed
  git switch $BASE_BRANCH && git merge --ff-only $1 && git push
EOF
}

# ── --finish: commit a sync whose conflicts were resolved by hand ─────────────
if [[ "$MODE" == finish ]]; then
    [[ -f "$STATE_FILE" ]] || fail "No sync in progress."
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    [[ "$(git branch --show-current)" == "$SYNC_BRANCH" ]] || fail "Switch to $SYNC_BRANCH first."
    if git grep -nE '^(<<<<<<<|>>>>>>>) ' -- "${KEEP_PATHS[@]}" > /dev/null; then
        git grep -lE '^(<<<<<<<|>>>>>>>) ' -- "${KEEP_PATHS[@]}" | sed 's/^/  conflict markers left in: /' >&2
        exit 2
    fi
    git add -A -- "${KEEP_PATHS[@]}"
    step "Building and testing"
    run_checks || fail "Build or tests still fail. Fix them, then run --finish again."
    commit_sync "$SYNC_UPSTREAM" "$SYNC_MESSAGE"
    rm -f "$STATE_FILE"
    finish_message "$SYNC_BRANCH" "$SYNC_UPSTREAM"
    exit 0
fi

[[ ! -f "$STATE_FILE" ]] || fail "A sync is already in progress (see $STATE_FILE). Finish it with --finish, or delete that file and its branch."
[[ -z "$(git status --porcelain)" ]] || fail "Working tree has uncommitted changes. Commit or stash them first."

# ── 1. Fetch upstream and see what is new ─────────────────────────────────────
if ! git remote get-url upstream > /dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_URL"
    git config remote.upstream.tagOpt --no-tags
fi
if [[ "$UPSTREAM_REF" == upstream/* ]]; then
    step "Fetching Mole ($UPSTREAM_URL)"
    git fetch --quiet --no-tags upstream
fi
upstream_sha=$(git rev-parse --verify --quiet "$UPSTREAM_REF^{commit}") || fail "Unknown upstream ref: $UPSTREAM_REF"
base_sha=$(git rev-parse --verify "$BASE_BRANCH^{commit}")

# The last Mole commit nixit already contains.
synced_sha=$(git merge-base "$base_sha" "$upstream_sha") || fail "nixit and $UPSTREAM_REF share no history."
if [[ "$synced_sha" == "$upstream_sha" ]]; then
    printf '%sAlready up to date%s with Mole %s.\n' "$G" "$N" "$(git log -1 --format='%h (%cs) %s' "$upstream_sha")"
    exit 0
fi

range="$synced_sha..$upstream_sha"
total=$(git rev-list --count --no-merges "$range")
NON_KEEP=(. "${KEEP_PATHS[@]/#/:!}")
go_commits=$(git log --no-merges --format='%h %s' "$range" -- "${KEEP_PATHS[@]}")
other_commits=$(git log --no-merges --format='%h %s' "$range" -- "${NON_KEEP[@]}")

step "Mole has $total new commit(s) since nixit last synced ($(git log -1 --format='%h, %cs' "$synced_sha"))"
printf '\n%sGo tools (merged automatically):%s\n' "$B" "$N"
printf '%s\n' "${go_commits:-(none)}" | sed 's/^/  /'
printf '\n%sShell commands, docs and CI (not merged; review for ideas to port):%s\n' "$B" "$N"
printf '%s\n' "${other_commits:-(none)}" | sed 's/^/  /'
printf '\n'

if [[ "$MODE" == check ]]; then
    note "Check only: nothing was changed."
    exit 0
fi

# ── 2. Merge each changed Go file on a sync branch ────────────────────────────
branch="sync/mole-$(date +%Y%m%d)"
suffix=1
while git show-ref --verify --quiet "refs/heads/$branch"; do
    suffix=$((suffix + 1))
    branch="sync/mole-$(date +%Y%m%d)-$suffix"
done
step "Merging into new branch $branch"
git switch --quiet -c "$branch" "$base_sha"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
show() { git show "$1:$2" 2> /dev/null | rename_for_nixit; }

declare -a merged=() added=() removed=() conflicted=() skipped=()
while IFS=$'\t' read -r status path new_path; do
    # Renames arrive as R<score> old new; treat as delete + add.
    if [[ "$status" == R* ]]; then
        printf 'D\t%s\nA\t%s\n' "$path" "$new_path"
        continue
    fi
    printf '%s\t%s\n' "${status:0:1}" "$path"
done < <(git diff --name-status -M "$synced_sha" "$upstream_sha" -- "${KEEP_PATHS[@]}") > "$tmp/changes"

while IFS=$'\t' read -r status path; do
    case "$status" in
        A | M)
            show "$upstream_sha" "$path" > "$tmp/theirs"
            # macOS-only stubs are replaced by real Linux code in nixit.
            if grep -q '^//go:build !darwin$' "$tmp/theirs"; then
                skipped+=("$path (macOS-only stub)")
                continue
            fi
            if [[ ! -e "$path" ]]; then
                if [[ "$status" == M ]]; then
                    skipped+=("$path (nixit removed this file)")
                    continue
                fi
                mkdir -p "$(dirname "$path")"
                cp "$tmp/theirs" "$path"
                added+=("$path")
            else
                show "$synced_sha" "$path" > "$tmp/base" # empty when the file is new upstream
                if git merge-file -q -L nixit -L "mole-$(git rev-parse --short "$synced_sha")" \
                    -L "mole-$(git rev-parse --short "$upstream_sha")" "$path" "$tmp/base" "$tmp/theirs"; then
                    merged+=("$path")
                else
                    conflicted+=("$path")
                fi
            fi
            ;;
        D)
            [[ -e "$path" ]] || continue
            show "$synced_sha" "$path" > "$tmp/base"
            if cmp -s "$tmp/base" "$path"; then
                rm -f "$path"
                removed+=("$path")
            else
                skipped+=("$path (Mole deleted it, but nixit changed it; kept)")
            fi
            ;;
    esac
done < "$tmp/changes"
git add -A -- "${KEEP_PATHS[@]}"

report() { # title items...
    local title="$1"
    shift
    (($# > 0)) || return 0
    printf '%s%s:%s\n' "$B" "$title" "$N"
    printf '  %s\n' "$@"
}
printf '\n'
report "Merged" "${merged[@]}"
report "Added" "${added[@]}"
report "Removed" "${removed[@]}"
report "Skipped" "${skipped[@]}"

message="Sync with Mole $(git rev-parse --short "$synced_sha")..$(git rev-parse --short "$upstream_sha")

Merges $total upstream Mole commit(s) into nixit's Go tools.
Generated by scripts/sync-mole.sh."

if ((${#conflicted[@]} > 0)); then
    {
        printf 'SYNC_BRANCH=%q\n' "$branch"
        printf 'SYNC_UPSTREAM=%q\n' "$upstream_sha"
        printf 'SYNC_MESSAGE=%q\n' "$message"
    } > "$STATE_FILE"
    printf '\n%sConflicts%s where Mole changed code nixit also changed for Linux:\n' "$Y" "$N"
    printf '  %s\n' "${conflicted[@]}"
    cat << EOF

The files above contain <<<<<<< nixit / >>>>>>> mole-... markers. To finish:
  1. Edit them, keeping nixit's Linux behaviour and Mole's new changes.
  2. scripts/sync-mole.sh --finish     (builds, tests and commits)
To give up: git reset --hard && git switch $BASE_BRANCH && git branch -D $branch && rm $STATE_FILE
EOF
    exit 2
fi

# ── 3. Build, test, commit ────────────────────────────────────────────────────
step "Building and testing"
if ! run_checks; then
    {
        printf 'SYNC_BRANCH=%q\n' "$branch"
        printf 'SYNC_UPSTREAM=%q\n' "$upstream_sha"
        printf 'SYNC_MESSAGE=%q\n' "$message"
    } > "$STATE_FILE"
    printf '\n%sBuild or tests failed%s after merging (changes are uncommitted on %s).\n' "$R" "$N" "$branch" >&2
    printf 'Fix them, then run: scripts/sync-mole.sh --finish\n' >&2
    exit 3
fi
commit_sync "$upstream_sha" "$message"
finish_message "$branch" "$upstream_sha"
