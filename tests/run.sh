#!/usr/bin/env bash
# Shell tests for nixit's safety helpers. Run: make test-shell

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" NO_COLOR=1
mkdir -p "$HOME"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

pass=0 fail=0
check() { # description command...
    local desc="$1"
    shift
    if "$@"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n' "$desc"
    fi
}
not() { ! "$@"; }

# ── is_protected_path ─────────────────────────────────────────────────────────
for p in / /usr /usr/bin /etc /etc/fstab /boot /boot/vmlinuz-linux /home /var /var/lib \
    /var/lib/pacman /var/lib/pacman/local "$HOME" "$HOME/" /home/someone relative/path \
    "$HOME/../etc" ""; do
    check "protected: '$p'" is_protected_path "$p"
done
for p in "$HOME/.cache/foo" /var/cache/pacman/pkg/x.pkg.tar.zst /var/lib/systemd/coredump/core.1 \
    /home/someone/.cache/x /tmp/whatever; do
    check "not protected: '$p'" not is_protected_path "$p"
done

# ── safe_rm ───────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.cache/app/sub" "$HOME/.cache/keepme"
touch "$HOME/.cache/app/sub/file"
NIXIT_DRY_RUN=1 safe_rm "$HOME/.cache/app" > /dev/null
check "dry run keeps files" test -e "$HOME/.cache/app/sub/file"
safe_rm "$HOME/.cache/app"
check "safe_rm removes" not test -e "$HOME/.cache/app"
safe_rm "$HOME" 2> /dev/null
check "safe_rm refuses HOME" test -d "$HOME"

mkdir -p "$XDG_CONFIG_HOME/nixit"
printf '# comment\n~/.cache/keep*\n' > "$XDG_CONFIG_HOME/nixit/whitelist"
load_whitelist
check "whitelist loaded" test "${#NIXIT_WHITELIST[@]}" -eq 1
check "whitelist matches glob" is_whitelisted "$HOME/.cache/keepme"
check "whitelist matches children" is_whitelisted "$HOME/.cache/keepme/inner"
check "whitelist ignores others" not is_whitelisted "$HOME/.cache/other"
safe_rm "$HOME/.cache/keepme" > /dev/null
check "safe_rm honors whitelist" test -d "$HOME/.cache/keepme"

# ── human_size ────────────────────────────────────────────────────────────────
check "human_size bytes" test "$(human_size 512)" = "512 B"
check "human_size KiB" test "$(human_size 1536)" = "1.5 KiB"
check "human_size GiB" test "$(human_size 10276044554)" = "9.6 GiB"
check "human_size junk" test "$(human_size abc)" = "0 B"

# ── purge artifact detection ──────────────────────────────────────────────────
eval "$(sed -n '/^is_artifact()/,/^}/p' "$ROOT/bin/purge.sh")"
P="$TMP/proj"
mkdir -p "$P/web/node_modules" "$P/rust/target" "$P/py/.venv" "$P/fake/node_modules" "$P/fake/target" "$P/c/build"
touch "$P/web/package.json" "$P/rust/Cargo.toml" "$P/py/.venv/pyvenv.cfg" "$P/c/CMakeLists.txt"
check "node_modules with package.json" is_artifact "$P/web/node_modules"
check "target with Cargo.toml" is_artifact "$P/rust/target"
check "venv with pyvenv.cfg" is_artifact "$P/py/.venv"
check "cmake build" is_artifact "$P/c/build"
check "node_modules without package.json" not is_artifact "$P/fake/node_modules"
check "target without Cargo.toml" not is_artifact "$P/fake/target"

# ── CLI ───────────────────────────────────────────────────────────────────────
check "nixit version" bash -c "'$ROOT/nixit' version | grep -q '^nixit '"
check "nixit help" bash -c "'$ROOT/nixit' help | grep -q 'Commands:'"
check "unknown command fails" not "$ROOT/nixit" bogus 2> /dev/null
for cmd in clean uninstall optimize purge; do
    check "$cmd --help" bash -c "'$ROOT/nixit' $cmd --help | grep -q 'Usage: nixit $cmd'"
done

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
