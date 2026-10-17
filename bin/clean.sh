#!/usr/bin/env bash
# nixit clean — free disk space on Arch/CachyOS.
#
# Scans package caches, app caches, Trash, logs, crash dumps, orphaned packages
# and developer caches, lets you pick what to remove, then removes it.
#
# Usage: nixit clean [--dry-run] [--yes]

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) NIXIT_DRY_RUN=1 ;;
        -y | --yes) ASSUME_YES=$((ASSUME_YES + 1)) ;;
        -h | --help)
            cat << EOF
Usage: nixit clean [--dry-run] [--yes]

Scan for reclaimable space, choose what to remove, then remove it.

  -n, --dry-run   Show what would be removed without changing anything
  -y, --yes       Clean every default-selected item without the picker
                  (orphaned packages are never included), but still ask
                  to confirm before removing. Pass it twice (-y -y) to
                  also skip that confirmation, for unattended runs.
  -h, --help      Show this help

Never removed: anything listed in ~/.config/nixit/whitelist (one glob per line),
and ~/.cache/yay, ~/.cache/paru, ~/.cache/nixit (nixit protects AUR helper
build caches and its own cache from the general "App caches" item; yay/paru
caches still show up as their own separate, opt-in items).
EOF
            exit 0
            ;;
        *) die "Unknown option: $arg (see nixit clean --help)" ;;
    esac
done

export LC_ALL=C
load_whitelist

USER_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
TRASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
JOURNAL_KEEP="100M"

# Entries in ~/.cache that have their own item, or that nixit must keep.
USER_CACHE_SKIP=(yay paru nixit)

declare -A ITEM_LABEL ITEM_SIZE ITEM_SUDO ITEM_NOTE ITEM_DEFAULT
ITEM_ORDER=()

add_item() { # id label size sudo(0/1) [note] [selected by default: 1/0]
    ITEM_ORDER+=("$1")
    ITEM_LABEL[$1]="$2"
    ITEM_SIZE[$1]="$3"
    ITEM_SUDO[$1]="$4"
    ITEM_NOTE[$1]="${5:-}"
    ITEM_DEFAULT[$1]="${6:-1}"
}

# "9.57 GiB" -> bytes
parse_human() {
    local value="${1// /}"
    value="${value%B}"
    [[ -z "$value" ]] && {
        printf 0
        return
    }
    if [[ "$value" == *i ]]; then
        numfmt --from=iec-i "$value" 2> /dev/null || printf 0
    else
        numfmt --from=iec "$value" 2> /dev/null || printf 0
    fi
}

paccache_savings() { # paccache args... -> bytes
    local line
    line=$(paccache -d "$@" 2> /dev/null | grep -o 'disk space saved: .*)' | tail -n1)
    line="${line#disk space saved: }"
    parse_human "${line%)}"
}

user_cache_entries() {
    local entry name skip
    [[ -d "$USER_CACHE" ]] || return 0
    for entry in "$USER_CACHE"/* "$USER_CACHE"/.[!.]*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name="${entry##*/}"
        for skip in "${USER_CACHE_SKIP[@]}"; do
            [[ "$name" == "$skip" ]] && continue 2
        done
        is_whitelisted "$entry" && continue
        printf '%s\n' "$entry"
    done
}

dev_cache_paths() {
    local p
    for p in \
        "$HOME/.npm/_cacache" \
        "$HOME/.cargo/registry/cache" \
        "$HOME/.cargo/git/checkouts" \
        "$HOME/go/pkg/mod/cache/download" \
        "$HOME/.local/share/pnpm/store" \
        "$HOME/.bun/install/cache" \
        "$HOME/.gradle/caches" \
        "$HOME/.m2/repository"; do
        [[ -d "$p" ]] && ! is_whitelisted "$p" && printf '%s\n' "$p"
    done
}

orphan_packages() { pacman -Qdtq 2> /dev/null; }

scan() {
    local size n

    if have paccache; then
        size=$(paccache_savings -k1)
        ((size > 0)) && add_item pacman_old "Pacman cache: old package versions (keeps newest)" "$size" 1
        size=$(paccache_savings -uk0)
        ((size > 0)) && add_item pacman_uninstalled "Pacman cache: packages no longer installed" "$size" 1
    fi

    size=$(dir_size "$USER_CACHE/yay")
    ((size > 0)) && add_item yay "yay build cache" "$size" 0
    size=$(dir_size "$USER_CACHE/paru/clone")
    ((size > 0)) && add_item paru "paru build cache" "$size" 0

    local -a caches
    mapfile -t caches < <(user_cache_entries)
    if ((${#caches[@]} > 0)); then
        size=$(dir_size "${caches[@]}")
        ((size > 0)) && add_item user_cache "App caches (~/.cache, ${#caches[@]} folders)" "$size" 0 "Apps rebuild these as needed"
    fi

    size=$(dir_size "$TRASH_DIR/files" "$TRASH_DIR/info" "$TRASH_DIR/expunged")
    ((size > 0)) && add_item trash "Trash" "$size" 0

    if have journalctl; then
        local usage keep
        usage=$(journalctl --disk-usage 2> /dev/null | grep -o 'take up [0-9.]*[KMGT]' | awk '{print $3}')
        size=$(parse_human "$usage")
        keep=$(parse_human "$JOURNAL_KEEP")
        ((size > keep)) && add_item journal "System logs (journal, keeps newest $JOURNAL_KEEP)" "$((size - keep))" 1
    fi

    if [[ -d /var/lib/systemd/coredump ]]; then
        size=$(sudo_dir_size /var/lib/systemd/coredump)
        ((size > 4096)) && add_item coredumps "Crash dumps (systemd-coredump)" "$size" 1
    fi

    local -a orphans
    mapfile -t orphans < <(orphan_packages)
    if ((${#orphans[@]} > 0)); then
        size=0
        while read -r n; do
            size=$((size + n))
        done < <(pacman -Qi "${orphans[@]}" 2> /dev/null | awk -F': ' '/^Installed Size/ {print $2}' |
            while read -r human; do parse_human "$human"; echo; done)
        add_item orphans "Orphaned packages (${#orphans[@]}: ${orphans[*]:0:4}$( ((${#orphans[@]} > 4)) && printf ', ...'))" "$size" 1 "Not selected by default: check you don't use them directly" 0
    fi

    local -a dev
    mapfile -t dev < <(dev_cache_paths)
    if ((${#dev[@]} > 0)); then
        size=$(dir_size "${dev[@]}")
        ((size > 0)) && add_item dev "Developer caches (npm, cargo, go, pnpm, bun, gradle, maven)" "$size" 0 "Re-downloaded on next build"
    fi

    if have flatpak && flatpak list --runtime --columns=application 2> /dev/null | grep -q .; then
        add_item flatpak "Unused Flatpak runtimes" 0 0 "Size shown after removal"
    fi
}

# ── Cleaners ──────────────────────────────────────────────────────────────────
clean_pacman_old() { run_or_echo sudo paccache -rqk1; }
clean_pacman_uninstalled() { run_or_echo sudo paccache -rquk0; }
clean_yay() { safe_rm "$USER_CACHE"/yay/*; }
clean_paru() { safe_rm "$USER_CACHE"/paru/clone/*; }
clean_user_cache() {
    local -a caches
    mapfile -t caches < <(user_cache_entries)
    safe_rm "${caches[@]}"
}
clean_trash() {
    if have gio && [[ "$NIXIT_DRY_RUN" != "1" ]]; then
        gio trash --empty 2> /dev/null && return
    fi
    safe_rm "$TRASH_DIR"/files/* "$TRASH_DIR"/files/.[!.]* "$TRASH_DIR"/info/* "$TRASH_DIR"/expunged/*
}
clean_journal() { run_or_echo sudo journalctl --vacuum-size="$JOURNAL_KEEP" -q; }
clean_coredumps() {
    if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
        dim "  would remove: everything in /var/lib/systemd/coredump"
        return
    fi
    local -a dumps
    mapfile -t dumps < <(sudo find /var/lib/systemd/coredump -mindepth 1 -maxdepth 1 2> /dev/null)
    ((${#dumps[@]} > 0)) && sudo_safe_rm "${dumps[@]}"
}
clean_orphans() {
    local -a orphans
    mapfile -t orphans < <(orphan_packages)
    ((${#orphans[@]} > 0)) || return 0
    run_quiet sudo pacman -Rns --noconfirm "${orphans[@]}"
}
clean_dev() {
    local -a dev
    mapfile -t dev < <(dev_cache_paths)
    safe_rm "${dev[@]}"
}
clean_flatpak() {
    if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
        dim "  would run: flatpak uninstall --unused"
        return
    fi
    flatpak uninstall --unused -y --noninteractive > /dev/null 2>&1 || true
}

# free_space -> available bytes summed over the filesystems that hold / and
# $HOME, counting each filesystem once (on btrfs both are usually the same one).
free_space() {
    df --output=source,avail -B1 / "$HOME" 2> /dev/null |
        awk 'NR>1 && !seen[$1]++ {s+=$2} END {print s+0}'
}

# ── Main ──────────────────────────────────────────────────────────────────────
header "nixit clean$([[ "$NIXIT_DRY_RUN" == "1" ]] && printf ' (dry run)')"

# The scan runs in a background subshell behind the spinner; its results come
# back as declare statements.
scan_and_dump() {
    scan
    declare -p ITEM_ORDER ITEM_LABEL ITEM_SIZE ITEM_SUDO ITEM_NOTE ITEM_DEFAULT
}
eval "$(spinner_run "Scanning for reclaimable space..." scan_and_dump)"

if ((${#ITEM_ORDER[@]} == 0)); then
    ok "Nothing to clean. Your system is already tidy."
    exit 0
fi

total=0
lines=()
unselected=""
row=0
for id in "${ITEM_ORDER[@]}"; do
    row=$((row + 1))
    [[ "${ITEM_DEFAULT[$id]}" == "1" ]] || unselected+=" $row"
    size="${ITEM_SIZE[$id]}"
    total=$((total + size))
    if ((size > 0)); then shown=$(human_size "$size"); else shown="?"; fi
    tag=""
    [[ "${ITEM_SUDO[$id]}" == "1" ]] && tag=" ${YELLOW}sudo${NC}"
    note=""
    [[ -n "${ITEM_NOTE[$id]}" ]] && note="  ${GRAY}${ITEM_NOTE[$id]}${NC}"
    lines+=("$(printf '%s\t%s%10s%s  %s%s%s' "$id" "$BOLD" "$shown" "$NC" "${ITEM_LABEL[$id]}" "$tag" "$note")")
done

if ((ASSUME_YES >= 1)); then
    selected=()
    for id in "${ITEM_ORDER[@]}"; do
        [[ "${ITEM_DEFAULT[$id]}" == "1" ]] && selected+=("$id")
    done
else
    picked=$(printf '%s\n' "${lines[@]}" | NO_COLOR='' pick_items "Clean" \
        "Found $(human_size "$total") · Tab toggle · Alt-A all · Alt-D none · Enter continue · Esc cancel" 1 "$unselected")
    [[ -z "$picked" ]] && {
        dim "Nothing selected."
        exit 0
    }
    mapfile -t selected < <(cut -f1 <<< "$picked")
fi

selected_total=0
needs_sudo=0
for id in "${selected[@]}"; do
    selected_total=$((selected_total + ITEM_SIZE[$id]))
    [[ "${ITEM_SUDO[$id]}" == "1" ]] && needs_sudo=1
done

printf '\n'
for id in "${selected[@]}"; do
    printf '  %s•%s %s\n' "$PURPLE" "$NC" "${ITEM_LABEL[$id]}"
done
printf '\n'

if [[ "$NIXIT_DRY_RUN" != "1" ]] && ((ASSUME_YES < 2)); then
    confirm "Remove these ${#selected[@]} items and free about $(human_size "$selected_total")?" || {
        dim "Cancelled. Nothing was removed."
        exit 0
    }
elif [[ "$NIXIT_DRY_RUN" != "1" ]]; then
    printf '%s%s⚠ REMOVING FOR REAL — no confirmation (-y -y): %d items, about %s%s\n\n' \
        "$RED" "$BOLD" "${#selected[@]}" "$(human_size "$selected_total")" "$NC"
fi

if [[ "$needs_sudo" == "1" && "$NIXIT_DRY_RUN" != "1" ]]; then
    ensure_sudo "package cache, logs and orphaned packages" || die "Could not get administrator access."
fi

free_before=$(free_space)

for id in "${selected[@]}"; do
    printf '%s➜%s %s\n' "$BLUE" "$NC" "${ITEM_LABEL[$id]}"
    "clean_$id"
done
stop_sudo_keepalive

if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
    printf '\n'
    ok "Dry run complete. About $(human_size "$selected_total") could be freed."
    exit 0
fi

sync
free_after=$(free_space)
freed=$((free_after - free_before))
printf '\n'
if ((freed > 0)); then
    ok "Done. Freed $(human_size "$freed") (estimated $(human_size "$selected_total"))."
else
    ok "Done. Removed about $(human_size "$selected_total")."
fi

if have snapper && snapper list-configs 2> /dev/null | grep -q '^root'; then
    dim "Tip: btrfs snapshots can still hold deleted files. Review them with: sudo snapper list"
fi
df -h / | awk 'NR==2 {printf "Disk /: %s used of %s (%s full)\n", $3, $2, $5}'
