#!/usr/bin/env bash
# nixit optimize — routine maintenance for Arch/CachyOS.
#
# Usage: nixit optimize [--dry-run] [--yes]

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) NIXIT_DRY_RUN=1 ;;
        -y | --yes) ASSUME_YES=1 ;;
        -h | --help)
            cat << EOF
Usage: nixit optimize [--dry-run] [--yes]

Pick maintenance tasks to run: refresh font, desktop and MIME caches, trim
SSDs, clear failed services, remove a stale pacman lock, check pacnew files
and rank mirrors.

  -n, --dry-run   Show what would run without changing anything
  -y, --yes       Run the default tasks without the picker
  -h, --help      Show this help
EOF
            exit 0
            ;;
        *) die "Unknown option: $arg (see nixit optimize --help)" ;;
    esac
done

export LC_ALL=C

declare -A TASK_LABEL TASK_SUDO TASK_DEFAULT
TASK_ORDER=()
add_task() { # id label sudo(0/1) default(0/1)
    TASK_ORDER+=("$1")
    TASK_LABEL[$1]="$2"
    TASK_SUDO[$1]="$3"
    TASK_DEFAULT[$1]="$4"
}

pacman_running() { pgrep -x 'pacman|yay|paru|pamac' > /dev/null 2>&1; }

discover() {
    have fc-cache && add_task fonts "Rebuild font cache" 0 1
    have update-desktop-database && add_task desktop "Refresh app launcher database" 0 1
    [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/mime" ]] && have update-mime-database &&
        add_task mime "Refresh file-type (MIME) database" 0 1
    have kbuildsycoca6 && add_task kde "Rebuild KDE service cache" 0 1

    local failed
    failed=$(systemctl --failed --no-legend 2> /dev/null | wc -l)
    failed=$((failed + $(systemctl --user --failed --no-legend 2> /dev/null | wc -l)))
    ((failed > 0)) && add_task failed "Clear $failed failed service(s) (systemctl reset-failed)" 1 1

    if have fstrim && ! systemctl is-enabled fstrim.timer > /dev/null 2>&1; then
        add_task trim "Trim SSDs now (fstrim.timer is not enabled)" 1 1
        add_task trimtimer "Enable weekly SSD trim (fstrim.timer)" 1 1
    fi

    if [[ -e /var/lib/pacman/db.lck ]] && ! pacman_running; then
        add_task lock "Remove stale pacman lock (no package manager running)" 1 1
    fi

    local count
    count=$(find /etc \( -name '*.pacnew' -o -name '*.pacsave' \) 2> /dev/null | wc -l)
    ((count > 0)) && add_task pacnew "List $count .pacnew/.pacsave config file(s) to review" 0 1

    have cachyos-rate-mirrors && add_task mirrors "Rank CachyOS + Arch mirrors by speed (takes a minute)" 1 0
    have btrfs && [[ "$(findmnt -no FSTYPE /)" == "btrfs" ]] &&
        add_task scrub "Start a btrfs scrub on / (checks data integrity in the background)" 1 0
}

task_fonts() { run_or_echo fc-cache -f; }
task_desktop() { run_or_echo update-desktop-database -q "${XDG_DATA_HOME:-$HOME/.local/share}/applications" 2> /dev/null; }
task_mime() { run_or_echo update-mime-database "${XDG_DATA_HOME:-$HOME/.local/share}/mime"; }
task_kde() { run_quiet kbuildsycoca6 --noincremental; }
task_failed() {
    run_or_echo sudo systemctl reset-failed
    run_or_echo systemctl --user reset-failed
}
task_trim() { run_or_echo sudo fstrim -av; }
task_trimtimer() { run_or_echo sudo systemctl enable --now fstrim.timer; }
task_lock() {
    pacman_running && {
        warn "A package manager started meanwhile; leaving the lock alone."
        return
    }
    run_or_echo sudo rm -f /var/lib/pacman/db.lck
}
task_pacnew() {
    find /etc \( -name '*.pacnew' -o -name '*.pacsave' \) 2> /dev/null | sed 's/^/  /'
    have pacdiff && dim "  Review and merge them with: sudo DIFFPROG=\"diff -u\" pacdiff"
}
task_mirrors() { run_or_echo sudo cachyos-rate-mirrors; }
task_scrub() { run_or_echo sudo btrfs scrub start / > /dev/null && dim "  Check progress with: sudo btrfs scrub status /"; }

header "nixit optimize$([[ "$NIXIT_DRY_RUN" == "1" ]] && printf ' (dry run)')"
discover

lines=()
unselected=""
row=0
for id in "${TASK_ORDER[@]}"; do
    row=$((row + 1))
    [[ "${TASK_DEFAULT[$id]}" == "1" ]] || unselected+=" $row"
    tag=""
    [[ "${TASK_SUDO[$id]}" == "1" ]] && tag="  ${YELLOW}sudo${NC}"
    lines+=("$(printf '%s\t%s%s' "$id" "${TASK_LABEL[$id]}" "$tag")")
done

if [[ "$ASSUME_YES" == "1" ]]; then
    selected=()
    for id in "${TASK_ORDER[@]}"; do
        [[ "${TASK_DEFAULT[$id]}" == "1" ]] && selected+=("$id")
    done
else
    picked=$(printf '%s\n' "${lines[@]}" | pick_items "Optimize" \
        "Tab toggle · Ctrl-A all · Ctrl-D none · Enter run · Esc cancel" 1 "$unselected")
    [[ -z "$picked" ]] && {
        dim "Nothing selected."
        exit 0
    }
    mapfile -t selected < <(cut -f1 <<< "$picked")
fi

needs_sudo=0
for id in "${selected[@]}"; do
    [[ "${TASK_SUDO[$id]}" == "1" ]] && needs_sudo=1
done
if [[ "$needs_sudo" == "1" && "$NIXIT_DRY_RUN" != "1" ]]; then
    ensure_sudo "system maintenance" || die "Could not get administrator access."
fi

failures=0
for id in "${selected[@]}"; do
    printf '%s➜%s %s\n' "$BLUE" "$NC" "${TASK_LABEL[$id]}"
    "task_$id" || {
        failures=$((failures + 1))
        warn "Task failed: ${TASK_LABEL[$id]}"
    }
done
stop_sudo_keepalive

printf '\n'
if ((failures == 0)); then
    ok "Optimize complete. Ran ${#selected[@]} task(s)."
else
    warn "Optimize finished with $failures failed task(s)."
fi
