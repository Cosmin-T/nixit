#!/usr/bin/env bash
# nixit purge — remove project build artifacts (node_modules, target, .venv...).
#
# Usage: nixit purge [--dry-run] [--paths] [dir...]

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PATHS_FILE="$NIXIT_CONFIG_DIR/purge_paths"
RECENT_DAYS=7
declare -a ROOTS=()

for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) NIXIT_DRY_RUN=1 ;;
        --paths)
            mkdir -p "$NIXIT_CONFIG_DIR"
            if [[ ! -f "$PATHS_FILE" ]]; then
                printf '# Folders nixit purge scans for projects, one per line.\n# ~ expands to your home folder.\n~/Projects\n' > "$PATHS_FILE"
            fi
            "${EDITOR:-nano}" "$PATHS_FILE"
            exit 0
            ;;
        -h | --help)
            cat << EOF
Usage: nixit purge [--dry-run] [--paths] [dir...]

Find build artifacts in your projects and remove the ones you pick:
node_modules, Rust target, Python virtualenvs, framework caches (.next, .nuxt,
.svelte-kit, .turbo, .parcel-cache), CMake/Gradle build folders, .gradle,
Zig caches, Elixir _build and .dart_tool. A folder only counts when its
project marker (package.json, Cargo.toml...) sits next to it.

Projects touched in the last $RECENT_DAYS days start unselected.

  -n, --dry-run   Show what would be removed without changing anything
      --paths     Edit the folders to scan ($PATHS_FILE)
  -h, --help      Show this help

Default folders: ~/Projects ~/projects ~/Code ~/code ~/dev ~/Developer ~/src
~/repos ~/workspace ~/Documents/GitHub
EOF
            exit 0
            ;;
        -*) die "Unknown option: $arg (see nixit purge --help)" ;;
        *) ROOTS+=("$(realpath -- "$arg")") ;;
    esac
done

load_whitelist

if ((${#ROOTS[@]} == 0)); then
    if [[ -f "$PATHS_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue
            [[ "$line" == "~"* ]] && line="$HOME${line:1}"
            ROOTS+=("$line")
        done < "$PATHS_FILE"
    else
        ROOTS=("$HOME/Projects" "$HOME/projects" "$HOME/Code" "$HOME/code" "$HOME/dev"
            "$HOME/Developer" "$HOME/src" "$HOME/repos" "$HOME/workspace" "$HOME/Documents/GitHub")
    fi
fi

existing=()
for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] && existing+=("$root")
done
ROOTS=("${existing[@]}")

# is_artifact DIR -> 0 when DIR is a build artifact of a real project.
is_artifact() {
    local dir="$1" parent name
    parent="${dir%/*}"
    name="${dir##*/}"
    case "$name" in
        node_modules | .next | .nuxt | .svelte-kit | .turbo | .parcel-cache | .angular)
            [[ -f "$parent/package.json" ]]
            ;;
        target) [[ -f "$parent/Cargo.toml" ]] ;;
        .venv | venv) [[ -f "$dir/pyvenv.cfg" ]] ;;
        build) [[ -f "$parent/CMakeLists.txt" || -f "$parent/build.gradle" || -f "$parent/build.gradle.kts" || -f "$parent/meson.build" ]] ;;
        .gradle) [[ -f "$parent/build.gradle" || -f "$parent/build.gradle.kts" || -f "$parent/settings.gradle" || -f "$parent/settings.gradle.kts" ]] ;;
        .zig-cache | zig-cache | zig-out) [[ -f "$parent/build.zig" ]] ;;
        _build) [[ -f "$parent/mix.exs" ]] ;;
        .dart_tool) [[ -f "$parent/pubspec.yaml" ]] ;;
        *) return 1 ;;
    esac
}

find_artifacts() {
    local dir
    find "${ROOTS[@]}" -xdev -type d \( -name .git -prune -o \( \
        -name node_modules -o -name .next -o -name .nuxt -o -name .svelte-kit -o -name .turbo \
        -o -name .parcel-cache -o -name .angular -o -name target -o -name .venv -o -name venv \
        -o -name build -o -name .gradle -o -name .zig-cache -o -name zig-cache -o -name zig-out \
        -o -name _build -o -name .dart_tool \) -prune -print \) 2> /dev/null |
        while IFS= read -r dir; do
            [[ "${dir##*/}" == .git ]] && continue
            is_artifact "$dir" || continue
            is_whitelisted "$dir" && continue
            # size<TAB>days-since-project-change<TAB>path
            local size mtime age
            size=$(dir_size "$dir")
            mtime=$(stat -c %Y -- "${dir%/*}" 2> /dev/null || echo 0)
            age=$((($(date +%s) - mtime) / 86400))
            printf '%s\t%s\t%s\n' "$size" "$age" "$dir"
        done | sort -t$'\t' -k1,1nr
}

header "nixit purge$([[ "$NIXIT_DRY_RUN" == "1" ]] && printf ' (dry run)')"

if ((${#ROOTS[@]} == 0)); then
    warn "No project folders found. Add some with: nixit purge --paths"
    exit 0
fi
dim "Scanning: ${ROOTS[*]/#$HOME/\~}"

found=$(spinner_run "Looking for build artifacts..." find_artifacts)
if [[ -z "$found" ]]; then
    ok "No build artifacts found."
    exit 0
fi

lines=()
unselected=""
row=0
total=0
while IFS=$'\t' read -r size age path; do
    row=$((row + 1))
    total=$((total + size))
    recent=""
    if ((age < RECENT_DAYS)); then
        unselected+=" $row"
        recent="  ${YELLOW}recent${NC}"
    fi
    lines+=("$(printf '%s\t%s%10s%s  %s  %s%sd ago%s%s' "$path" "$BOLD" "$(human_size "$size")" "$NC" \
        "${path/#$HOME/\~}" "$GRAY" "$age" "$NC" "$recent")")
done <<< "$found"

picked=$(printf '%s\n' "${lines[@]}" | pick_items "Purge" \
    "Found $(human_size "$total") · Tab toggle · Ctrl-A all · Ctrl-D none · Enter continue · Esc cancel" 1 "$unselected")
[[ -z "$picked" ]] && {
    dim "Nothing selected."
    exit 0
}
mapfile -t selected < <(cut -f1 <<< "$picked")

selected_total=0
while IFS=$'\t' read -r size _ path; do
    for s in "${selected[@]}"; do
        [[ "$s" == "$path" ]] && selected_total=$((selected_total + size))
    done
done <<< "$found"

if [[ "$NIXIT_DRY_RUN" != "1" ]]; then
    confirm "Remove ${#selected[@]} folder(s) and free $(human_size "$selected_total")?" || {
        dim "Cancelled. Nothing was removed."
        exit 0
    }
fi

for path in "${selected[@]}"; do
    # Re-check right before removal: the tree may have changed since the scan.
    is_artifact "$path" || {
        warn "Skipped (no longer looks like a build artifact): $path"
        continue
    }
    safe_rm "$path"
done

if [[ "$NIXIT_DRY_RUN" == "1" ]]; then
    ok "Dry run complete. About $(human_size "$selected_total") could be freed."
else
    ok "Purged ${#selected[@]} folder(s), freed about $(human_size "$selected_total")."
fi
