#!/usr/bin/env bash
# nixit shared helpers: colors, output, sizes, prompts, sudo and safe removal.
# Sourced by the nixit entrypoint and every bin/*.sh command.

[[ -n "${NIXIT_COMMON_LOADED:-}" ]] && return 0
NIXIT_COMMON_LOADED=1

NIXIT_ROOT="${NIXIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NIXIT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nixit"
NIXIT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nixit"
NIXIT_DRY_RUN="${NIXIT_DRY_RUN:-0}"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m' PURPLE=$'\033[0;35m' CYAN=$'\033[0;36m' GRAY=$'\033[0;38;5;244m'
else
    BOLD='' DIM='' NC='' RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' GRAY=''
fi

# ── Output ────────────────────────────────────────────────────────────────────
info() { printf '%s➜%s %s\n' "$BLUE" "$NC" "$*"; }
ok() { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err() { printf '%s✗%s %s\n' "$RED" "$NC" "$*" >&2; }
die() {
    err "$*"
    exit 1
}
header() { printf '\n%s%s%s\n\n' "$PURPLE$BOLD" "$*" "$NC"; }
dim() { printf '%s%s%s\n' "$GRAY" "$*" "$NC"; }

have() { command -v "$1" > /dev/null 2>&1; }

# ── Sizes ─────────────────────────────────────────────────────────────────────
# human_size BYTES -> "1.2 GiB"
human_size() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if ((bytes < 1024)); then
        printf '%d B' "$bytes"
    else
        LC_ALL=C numfmt --to=iec-i --suffix=B --format='%.1f' "$bytes" | sed -E 's/([0-9])([KMGTP])/\1 \2/'
    fi
}

# dir_size PATH... -> bytes on disk (0 when missing). Never crosses filesystems.
dir_size() {
    local total=0 path size
    for path in "$@"; do
        [[ -e "$path" || -L "$path" ]] || continue
        size=$(du -sxb -- "$path" 2> /dev/null | awk '{print $1}')
        total=$((total + ${size:-0}))
    done
    printf '%d' "$total"
}

# sudo_dir_size PATH -> bytes, reading root-only directories through sudo.
sudo_dir_size() {
    local path="$1" size
    [[ -e "$path" ]] || {
        printf 0
        return
    }
    if [[ -r "$path" && -x "$path" ]]; then
        dir_size "$path"
        return
    fi
    size=$(sudo -n du -sxb -- "$path" 2> /dev/null | awk '{print $1}')
    printf '%d' "${size:-0}"
}

# ── Prompts ───────────────────────────────────────────────────────────────────
# confirm "Question" -> 0 on yes. Defaults to no.
confirm() {
    local reply
    printf '%s?%s %s %s[y/N]%s ' "$CYAN" "$NC" "$1" "$GRAY" "$NC"
    read -r reply < /dev/tty || return 1
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

pause_for_key() {
    [[ -t 0 ]] || return 0
    printf '\n%sPress any key to return...%s' "$GRAY" "$NC"
    read -rsn1 < /dev/tty || true
    printf '\n'
}

# spinner_run "Message" cmd args... runs cmd with a spinner on stderr and
# returns its exit status. Output of cmd is passed through on stdout.
spinner_run() {
    local msg="$1"
    shift
    if [[ ! -t 2 ]]; then
        "$@"
        return
    fi
    local frames=('⠖' '⠲' '⠴' '⠦') i=0 tmp status
    tmp=$(mktemp)
    "$@" > "$tmp" &
    local pid=$!
    while kill -0 "$pid" 2> /dev/null; do
        printf '\r%s%s%s %s' "$PURPLE" "${frames[i++ % 4]}" "$NC" "$msg" >&2
        sleep 0.1
    done
    wait "$pid"
    status=$?
    printf '\r\033[2K' >&2
    cat "$tmp"
    rm -f "$tmp"
    return "$status"
}

# ── sudo ──────────────────────────────────────────────────────────────────────
NIXIT_SUDO_KEEPALIVE_PID=""

# ensure_sudo "reason" -> asks for the password once and keeps it fresh.
ensure_sudo() {
    sudo -n true 2> /dev/null && return 0
    info "Administrator access needed: ${1:-system cleanup}"
    sudo -v || return 1
    if [[ -z "$NIXIT_SUDO_KEEPALIVE_PID" ]]; then
        (while kill -0 "$$" 2> /dev/null; do
            sudo -n true 2> /dev/null
            sleep 50
        done) &
        NIXIT_SUDO_KEEPALIVE_PID=$!
        disown "$NIXIT_SUDO_KEEPALIVE_PID" 2> /dev/null || true
    fi
}

stop_sudo_keepalive() {
    [[ -n "$NIXIT_SUDO_KEEPALIVE_PID" ]] && kill "$NIXIT_SUDO_KEEPALIVE_PID" 2> /dev/null
    NIXIT_SUDO_KEEPALIVE_PID=""
}

# ── Whitelist ─────────────────────────────────────────────────────────────────
# ~/.config/nixit/whitelist holds one glob per line (# comments allowed). Any
# path that matches is never removed. Leading ~ expands to $HOME.
NIXIT_WHITELIST=()
load_whitelist() {
    NIXIT_WHITELIST=()
    local file="$NIXIT_CONFIG_DIR/whitelist" line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" == "~"* ]] && line="$HOME${line:1}"
        NIXIT_WHITELIST+=("$line")
    done < "$file"
}

is_whitelisted() {
    local path="$1" pattern
    for pattern in "${NIXIT_WHITELIST[@]}"; do
        # shellcheck disable=SC2053 # glob match is intended
        [[ "$path" == $pattern || "$path" == $pattern/* ]] && return 0
    done
    return 1
}

# ── Safe removal ──────────────────────────────────────────────────────────────
# Paths nixit must never remove, however a caller computed them.
is_protected_path() {
    local path="${1%/}"
    [[ -z "$path" ]] && return 0
    case "$path" in
        / | /bin | /boot | /dev | /efi | /etc | /home | /lib | /lib64 | /mnt | /media | /opt | \
            /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /var/lib | /var/cache | \
            /var/log | /var/lib/pacman | /var/lib/pacman/* | /usr/* | /etc/* | /boot/* | /efi/*)
            return 0
            ;;
    esac
    [[ "$path" == "$HOME" || "$path" == "${HOME%/}" ]] && return 0
    # Another account's home root.
    [[ "$path" =~ ^/home/[^/]+$ ]] && return 0
    # Relative paths and traversal are never accepted.
    [[ "$path" != /* || "$path/" == */../* ]] && return 0
    return 1
}

# safe_rm PATH... removes paths (recursively) unless protected or whitelisted.
# Honors NIXIT_DRY_RUN. Prints nothing on success.
safe_rm() {
    local path
    for path in "$@"; do
        [[ -e "$path" || -L "$path" ]] || continue
        if is_protected_path "$path"; then
            warn "Refusing to remove protected path: $path"
            continue
        fi
        if is_whitelisted "$path"; then
            dim "  kept (whitelist): $path"
            continue
        fi
        if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
            dim "  would remove: $path"
            continue
        fi
        rm -rf --one-file-system -- "$path" 2> /dev/null || warn "Could not fully remove $path"
    done
}

# sudo_safe_rm PATH... is safe_rm for root-owned paths.
sudo_safe_rm() {
    local path
    for path in "$@"; do
        if is_protected_path "$path"; then
            warn "Refusing to remove protected path: $path"
            continue
        fi
        if is_whitelisted "$path"; then
            dim "  kept (whitelist): $path"
            continue
        fi
        if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
            dim "  would remove: $path"
            continue
        fi
        sudo rm -rf --one-file-system -- "$path" 2> /dev/null || warn "Could not fully remove $path"
    done
}

# move_to_trash PATH... sends paths to the desktop Trash (recoverable).
move_to_trash() {
    local path
    for path in "$@"; do
        [[ -e "$path" || -L "$path" ]] || continue
        if is_protected_path "$path"; then
            warn "Refusing to trash protected path: $path"
            continue
        fi
        if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
            dim "  would trash: $path"
            continue
        fi
        gio trash -- "$path" 2> /dev/null || safe_rm "$path"
    done
}

# run_or_echo cmd args... executes, or prints the command in dry-run mode.
run_or_echo() {
    if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
        dim "  would run: $*"
        return 0
    fi
    "$@"
}

# run_quiet cmd args... is run_or_echo with the command's output discarded.
run_quiet() {
    if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
        dim "  would run: $*"
        return 0
    fi
    "$@" > /dev/null 2>&1
}

# ── Selection (fzf) ───────────────────────────────────────────────────────────
# pick_items "Prompt" "header" [select_all] [unselected_positions] < lines
# -> selected lines on stdout. Lines are "id<TAB>display"; only the display part
# is shown. unselected_positions is a space-separated list of 1-based rows that
# start unselected when select_all is 1.
pick_items() {
    local prompt="$1" header="$2" select_all="${3:-1}" unselected="${4:-}"
    have fzf || die "fzf is required (sudo pacman -S fzf)"
    local -a args=(
        --multi --ansi --reverse --height=~90% --border=rounded
        --delimiter=$'\t' --with-nth=2..
        --prompt="$prompt > " --header="$header"
        --header-first --info=inline-right
        --color='pointer:magenta,marker:green,header:gray,prompt:magenta'
        --bind='alt-a:select-all,alt-d:deselect-all'
    )
    if [[ "$select_all" == "1" ]]; then
        local load='select-all' pos
        for pos in $unselected; do
            load+="+pos($pos)+deselect"
        done
        [[ -n "$unselected" ]] && load+='+first'
        args+=(--bind="load:$load")
    fi
    fzf "${args[@]}"
}
