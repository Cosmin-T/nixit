#!/usr/bin/env bash
# sync-mole.sh — bring new upstream Mole commits into nixit.
#
# nixit keeps Mole's Go tools (cmd/, internal/, go.mod, go.sum) and merges
# their upstream changes. Everything else (the shell commands, docs, CI) was
# rewritten for Arch, so upstream changes there are only listed for review.
#
# How it works:
#   1. Fetch Mole into the "upstream" remote.
#   2. Build a "prepared" commit on top of upstream: Mole's Go code with the
#      nixit rename applied (module path, command names, cache dirs, darwin ->
#      linux build tags) and our own versions of every non-Go path. Because
#      both sides then contain the same rename, it never causes conflicts.
#   3. Merge that commit into a new sync/mole-<date> branch off main.
#   4. Build and test. Nothing is pushed and main is never touched.
#
# Usage: scripts/sync-mole.sh [--check] [--upstream-ref REF] [--base BRANCH]

set -euo pipefail

UPSTREAM_URL="https://github.com/tw93/Mole.git"
UPSTREAM_REF="upstream/main"
BASE_BRANCH="main"
CHECK_ONLY=0
# Paths whose upstream changes are merged. Everything else is nixit's own.
KEEP_PATHS=(cmd internal go.mod go.sum)

while (($#)); do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --upstream-ref)
            UPSTREAM_REF="$2"
            shift
            ;;
        --base)
            BASE_BRANCH="$2"
            shift
            ;;
        -h | --help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
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

[[ -z "$(git status --porcelain)" ]] || fail "Working tree has uncommitted changes. Commit or stash them first."

# ── 1. Fetch upstream ─────────────────────────────────────────────────────────
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
go_commits=$(git log --no-merges --format='%h %s' "$range" -- "${KEEP_PATHS[@]}")
other_commits=$(git log --no-merges --format='%h %s' "$range" -- . "${KEEP_PATHS[@]/#/:!}")

step "Mole has $total new commit(s) since nixit last synced ($(git log -1 --format='%h, %cs' "$synced_sha"))"
printf '\n%sGo tools (merged automatically):%s\n' "$B" "$N"
printf '%s\n' "${go_commits:-  (none)}" | sed 's/^/  /'
printf '\n%sShell commands, docs and CI (not merged; review for ideas to port):%s\n' "$B" "$N"
printf '%s\n' "${other_commits:-  (none)}" | sed 's/^/  /'
printf '\n'

if ((CHECK_ONLY)); then
    note "Check only: nothing was changed."
    exit 0
fi

if [[ -z "$go_commits" ]]; then
    printf '%sNothing to merge:%s the new commits do not touch the Go tools.\n' "$G" "$N"
    note "Review the list above for features worth porting by hand."
    exit 0
fi

# ── 2. Prepared commit: upstream Go code, renamed; nixit's everything else ────
step "Preparing Mole $(git rev-parse --short "$upstream_sha") for nixit"
work=$(mktemp -d)
cleanup() {
    git worktree remove --force "$work" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
git worktree add --quiet --detach "$work" "$upstream_sha"

# Pathspecs for "everything except the Go tools".
NON_KEEP=(. "${KEEP_PATHS[@]/#/:!}")

(
    cd "$work"
    # Non-Go paths: drop upstream's, take nixit's.
    git ls-files -z -- "${NON_KEEP[@]}" > "$work.list"
    xargs -0 -r git rm --quiet --cached -- < "$work.list"
    rm -f "$work.list"
    git checkout --quiet "$base_sha" -- "${NON_KEEP[@]}"
    git clean -fdq -- "${NON_KEEP[@]}"

    # macOS-only stubs (//go:build !darwin) are replaced by real Linux code.
    grep -rlZ --include='*.go' '^//go:build !darwin$' cmd internal 2> /dev/null | xargs -0 -r git rm --quiet --

    # The nixit rename, identical to the one in nixit's history, so it merges cleanly.
    grep -rlIZ -E 'tw93/mole|\bmo (status|analyze|uninstall|clean|purge)\b|"mole"|MOLE_|Mole|moleCacheRoot|//go:build darwin' \
        cmd internal go.mod 2> /dev/null |
        xargs -0 -r sed -i -E \
            -e 's#^//go:build darwin$#//go:build linux#' \
            -e 's#github.com/tw93/mole#github.com/Cosmin-T/nixit#g' \
            -e 's/\bmo (status|analyze|uninstall|clean|purge)\b/nixit \1/g' \
            -e 's/"\.cache", "mole"/".cache", "nixit"/g' -e 's/"\.config", "mole"/".config", "nixit"/g' \
            -e 's#~/\.cache/mole#~/.cache/nixit#g' -e 's#~/\.config/mole#~/.config/nixit#g' \
            -e 's/MOLE_/NIXIT_/g' -e "s/\bMole's\b/nixit's/g" -e 's/\bMole\b/nixit/g' \
            -e 's/moleCacheRoot/nixitCacheRoot/g' -e 's/getMoleCacheRoot/getNixitCacheRoot/g'

    git add -A
    git -c user.name="$(git -C "$ROOT" config user.name)" -c user.email="$(git -C "$ROOT" config user.email)" \
        commit --quiet --no-verify -m "Prepare Mole $(git rev-parse --short "$upstream_sha") for nixit

Mole's Go tools renamed for nixit; every other path is nixit's own.
Generated by scripts/sync-mole.sh."
)
prepared_sha=$(git -C "$work" rev-parse HEAD)

# ── 3. Merge into a sync branch ───────────────────────────────────────────────
branch="sync/mole-$(date +%Y%m%d)"
suffix=1
while git show-ref --verify --quiet "refs/heads/$branch"; do
    suffix=$((suffix + 1))
    branch="sync/mole-$(date +%Y%m%d)-$suffix"
done
step "Merging into new branch $branch"
git switch --quiet -c "$branch" "$base_sha"

merge_msg="Sync with Mole $(git rev-parse --short "$synced_sha")..$(git rev-parse --short "$upstream_sha")

Merges $total upstream Mole commit(s) into nixit's Go tools.
Generated by scripts/sync-mole.sh."
if ! git merge --quiet --no-ff --no-edit -m "$merge_msg" "$prepared_sha"; then
    printf '\n%sMerge conflicts%s in files where Mole changed code nixit also changed for Linux:\n' "$Y" "$N"
    git diff --name-only --diff-filter=U | sed 's/^/  /'
    cat << EOF

The merge is left in progress on branch $branch. To finish:
  1. Fix the conflicts in the files above (keep the Linux behaviour).
  2. git add <files> && git commit
  3. make build && make test
To give up: git merge --abort && git switch $BASE_BRANCH && git branch -D $branch
EOF
    exit 2
fi

# ── 4. Build and test ─────────────────────────────────────────────────────────
step "Building and testing"
if ! { go build ./... && go vet ./... && go test ./... && bash tests/run.sh; } > "$work.log" 2>&1; then
    tail -n 40 "$work.log" >&2
    printf '\n%sBuild or tests failed%s after merging. The merge is committed on %s.\n' "$R" "$N" "$branch" >&2
    printf 'Fix it there, or drop it: git switch %s && git branch -D %s\n' "$BASE_BRANCH" "$branch" >&2
    rm -f "$work.log"
    exit 3
fi
rm -f "$work.log"
make build > /dev/null 2>&1 || true

printf '\n%sSynced.%s Branch %s merges %d Mole commit(s); build and tests pass.\n' "$G" "$N" "$branch" "$total"
cat << EOF

Next:
  git diff $BASE_BRANCH --stat          # review what changed
  git switch $BASE_BRANCH && git merge --ff-only $branch && git push
EOF
