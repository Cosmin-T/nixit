#!/usr/bin/env bash
# nixit uninstall — remove packages and Flatpak apps along with their leftovers.
#
# Usage: nixit uninstall [--dry-run] [package...]

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

VERBOSE=0
declare -a REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) NIXIT_DRY_RUN=1 ;;
        -v | --verbose) VERBOSE=1 ;;
        -h | --help)
            cat << EOF
Usage: nixit uninstall [--dry-run] [--verbose] [package...]

Pick installed packages and Flatpak apps to remove. nixit removes each package
with its unneeded dependencies (pacman -Rns), then offers to move the app's
leftover config, data and cache folders to the Trash.

  -n, --dry-run   Show what would be removed without changing anything
  -v, --verbose   Show pacman's full dependency-conflict output, if any
  -h, --help      Show this help
EOF
            exit 0
            ;;
        -*) die "Unknown option: $arg (see nixit uninstall --help)" ;;
        *) REQUESTED+=("$arg") ;;
    esac
done

export LC_ALL=C

# list_candidates -> "kind:name<TAB>display" for explicitly installed packages
# and Flatpak apps, biggest first.
list_candidates() {
    {
        pacman -Qei 2> /dev/null | awk -F': ' '
            /^Name/ {name=$2}
            /^Installed Size/ {size=$2}
            /^Description/ {desc=$2}
            /^$/ && name {print "pkg:" name "\t" size "\t" desc; name=""}'
        if have flatpak; then
            flatpak list --app --columns=application,size,name 2> /dev/null |
                awk -F'\t' 'NF>=2 {print "flatpak:" $1 "\t" $2 "\t" $3 " (Flatpak)"}'
        fi
    } | while IFS=$'\t' read -r key size desc; do
        local bytes
        bytes=$(numfmt --from=iec-i "$(sed -E 's/ //g; s/B$//; s/([KMGT])$/\1i/' <<< "$size")" 2> /dev/null || echo 0)
        printf '%s\t%s\t%s\t%s\n' "$bytes" "$key" "$size" "$desc"
    done | sort -t$'\t' -k1,1nr | awk -F'\t' -v b="$BOLD" -v n="$NC" -v g="$GRAY" '{
        name=$2; sub(/^[a-z]+:/, "", name)
        printf "%s\t%s%10s%s  %-32s %s%s%s\n", $2, b, $3, n, name, g, $4, n
    }'
}

# leftovers NAME -> per-user folders that probably belong to the app.
leftovers() {
    local name="$1" base dir candidate
    local -a names=("$name")
    # foo-bin / foo-git / foo-appimage -> foo
    base=$(sed -E 's/-(bin|git|appimage|beta|nightly|stable|desktop)$//' <<< "$name")
    [[ "$base" != "$name" ]] && names+=("$base")
    # org.example.App -> App
    [[ "$name" == *.*.* ]] && names+=("${name##*.}")
    for candidate in "${names[@]}"; do
        for dir in \
            "${XDG_CONFIG_HOME:-$HOME/.config}" \
            "${XDG_DATA_HOME:-$HOME/.local/share}" \
            "${XDG_CACHE_HOME:-$HOME/.cache}" \
            "${XDG_STATE_HOME:-$HOME/.local/state}" \
            "$HOME/.var/app"; do
            # Case-insensitive exact-name match.
            find "$dir" -mindepth 1 -maxdepth 1 -iname "$candidate" 2> /dev/null
        done
        [[ -e "$HOME/.$candidate" ]] && printf '%s\n' "$HOME/.$candidate"
    done | sort -u
}

header "nixit uninstall$([[ "$NIXIT_DRY_RUN" == "1" ]] && printf ' (dry run)')"

declare -a selected=()
if ((${#REQUESTED[@]} > 0)); then
    for name in "${REQUESTED[@]}"; do
        if pacman -Qq "$name" > /dev/null 2>&1; then
            selected+=("pkg:$name")
        elif have flatpak && flatpak info "$name" > /dev/null 2>&1; then
            selected+=("flatpak:$name")
        else
            warn "Not installed: $name"
        fi
    done
else
    candidates=$(spinner_run "Listing installed apps..." list_candidates)
    picked=$(pick_items "Uninstall" "Tab select · Enter continue · Esc cancel · sorted by size" 0 <<< "$candidates")
    [[ -n "$picked" ]] && mapfile -t selected < <(cut -f1 <<< "$picked")
fi

((${#selected[@]} > 0)) || {
    dim "Nothing selected."
    exit 0
}

declare -a pkgs=() flatpaks=() junk=()
for key in "${selected[@]}"; do
    name="${key#*:}"
    case "$key" in
        pkg:*) pkgs+=("$name") ;;
        flatpak:*) flatpaks+=("$name") ;;
    esac
    while IFS= read -r path; do
        [[ -n "$path" ]] && junk+=("$path")
    done < <(leftovers "$name")
done

if ((${#pkgs[@]} > 0)); then
    printf '%sPackages%s (with dependencies nothing else needs):\n' "$BOLD" "$NC"
    # pacman -Rs --print lists exactly what would go. When removal would break
    # another package's dependency, pacman writes a "removing X breaks
    # dependency..." line to stdout per conflict instead (hundreds for core
    # packages like glibc), so that's captured and summarized rather than
    # dumped, unless --verbose asks for the full detail.
    pacman_print=$(pacman -Rs --print --print-format '  %n %v' "${pkgs[@]}" 2>&1)
    pacman_status=$?
    if ((pacman_status == 0)); then
        printf '%s\n' "$pacman_print"
    elif ((VERBOSE == 1)); then
        printf '%s\n' "$pacman_print"
    else
        printf '  %s\n' "${pkgs[@]}"
        conflicts=$(grep -c '^:: removing' <<< "$pacman_print")
        warn "pacman reports removing these would break $conflicts other package dependency/dependencies (see: nixit uninstall --verbose)."
    fi
fi
if ((${#flatpaks[@]} > 0)); then
    printf '%sFlatpak apps:%s\n' "$BOLD" "$NC"
    printf '  %s\n' "${flatpaks[@]}"
fi
if ((${#junk[@]} > 0)); then
    printf '%sLeftover folders%s (moved to Trash, recoverable):\n' "$BOLD" "$NC"
    for path in "${junk[@]}"; do
        printf '  %s %s(%s)%s\n' "${path/#$HOME/\~}" "$GRAY" "$(human_size "$(dir_size "$path")")" "$NC"
    done
fi
printf '\n'

if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
    ok "Dry run complete. Nothing was removed."
    exit 0
fi

confirm "Uninstall ${#selected[@]} app(s)?" || {
    dim "Cancelled. Nothing was removed."
    exit 0
}

status=0
if ((${#pkgs[@]} > 0)); then
    ensure_sudo "remove packages" || die "Could not get administrator access."
    sudo pacman -Rns --noconfirm "${pkgs[@]}" || {
        status=1
        err "pacman could not remove the packages. Leftover folders were kept."
        junk=()
    }
fi
if ((${#flatpaks[@]} > 0)); then
    flatpak uninstall -y --noninteractive --delete-data "${flatpaks[@]}" || status=1
fi
if ((${#junk[@]} > 0)); then
    if confirm "Also move ${#junk[@]} leftover folder(s) to the Trash?"; then
        move_to_trash "${junk[@]}"
    fi
fi
stop_sudo_keepalive

((status == 0)) && ok "Uninstall complete." || warn "Uninstall finished with errors."
exit "$status"
