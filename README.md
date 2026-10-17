# nixit

**Clean and tune your Arch system from the terminal.**

> **nixit is built on [Mole](https://github.com/tw93/Mole), created by
> [tw93](https://github.com/tw93).** Mole is a terminal tool that deep-cleans,
> uninstalls apps, optimizes, analyzes disk usage and monitors macOS. nixit
> started as a fork of it, and its disk analyzer and status dashboard are
> Mole's code ported to Linux. All credit for the original design and those
> tools goes to tw93 and Mole's contributors. If you use a Mac, use Mole:
> [github.com/tw93/Mole](https://github.com/tw93/Mole) · [mole.fit](https://mole.fit).
>
> nixit is an independent project and is not affiliated with or endorsed by
> Mole or its authors. "Mole" and its logo are trademarks of the Mole project.

nixit brings Mole's idea to Arch Linux and CachyOS. It frees disk space,
removes apps with their leftovers, runs routine maintenance, shows what is
eating your disk and gives you a live system dashboard, all from one menu.

```
         _       _ _
   _ __ (_)_  __(_) |_
  | '_ \| \ \/ /| | __|
  | | | | |>  < | | |_
  |_| |_|_/_/\_\|_|\__|
  Clean and tune your Arch system.

  ➤ 1. Clean        Free up disk space
    2. Uninstall    Remove apps and their leftovers
    3. Optimize     Refresh caches and run maintenance
    4. Analyze      Explore disk usage
    5. Status       Monitor system health
    6. Purge        Remove project build artifacts
```

## Install

From the nixit pacman repo (prebuilt binary, no AUR account/helper needed).
Add to `/etc/pacman.conf`:

```ini
[nixit]
Server = https://cosmin-t.github.io/nixit/x86_64
```

Then:

```sh
sudo pacman -Syu
sudo pacman -S nixit
```

Updates arrive through your normal `pacman -Syu`.

### From the AUR

AUR account registration is temporarily closed, so this isn't live yet.
Once it is:

```sh
yay -S nixit-git
# or
paru -S nixit-git
```

Update with your AUR helper as usual (`yay -Syu` / `paru -Syu`).

### From source

Needs `bash`, `fzf`, `pacman-contrib` (for `paccache`), `glib2` (for `gio`) and
`go` to build.

```sh
sudo pacman -S --needed fzf pacman-contrib glib2 go
git clone https://github.com/Cosmin-T/nixit.git ~/Projects/nixit
cd ~/Projects/nixit
make install        # builds the Go tools, links ~/.local/bin/nixit
```

Update a source install with `nixit update`. Remove it with `make uninstall`.

## Commands

| Command | What it does |
|---|---|
| `nixit` | Opens the menu |
| `nixit clean` | Finds reclaimable space and lets you pick what to remove: old pacman package versions (keeps the newest), packages no longer installed, yay/paru build caches, `~/.cache`, Trash, the systemd journal (keeps 100 MB), crash dumps, developer caches (npm, cargo, go, pnpm, bun, gradle, maven), unused Flatpak runtimes and, opt-in, orphaned packages |
| `nixit uninstall [pkg...]` | Pick packages or Flatpak apps, sorted by size. Removes them with `pacman -Rns`, then offers to move their leftover config/data/cache folders to the Trash |
| `nixit optimize` | Rebuilds font, launcher, MIME and KDE caches, clears failed services, trims SSDs, removes a stale pacman lock, lists `.pacnew` files to review and, opt-in, ranks mirrors or starts a btrfs scrub |
| `nixit analyze [path]` | Interactive disk explorer with a hidden-space overview (pacman cache, journal, Trash, Flatpak, Steam shaders...). Deletes go to the Trash |
| `nixit status` | Live dashboard: CPU with temperature, memory and pressure, disks, GPU (AMD/Intel via sysfs, NVIDIA via `nvidia-smi`) or battery, processes and network |
| `nixit purge` | Finds `node_modules`, Rust `target`, Python venvs and other build folders in your projects. Projects touched in the last 7 days start unselected |

Every cleaning command takes `--dry-run` to preview without changing anything,
and `--help` for details.

## Safety

- Nothing is removed until you confirm, and `--dry-run` shows exactly what would go.
- System paths (`/usr`, `/etc`, `/boot`, `/var/lib/pacman`, your home folder itself...)
  are refused no matter how a path was computed.
- Packages are only ever removed through pacman, never by deleting files.
- Orphaned packages are opt-in: tools like `go` or `rust` often show up as
  orphans while you still use them.
- `analyze` deletes and `uninstall` leftovers go to the Trash, so you can restore them.
- Add globs to `~/.config/nixit/whitelist` (one per line) to protect paths:

  ```
  ~/.cache/my-important-cache
  ~/Projects/keep-this/node_modules
  ```

## Building and testing

```sh
make build   # bin/analyze-go and bin/status-go
make test    # Go tests + shell tests
make check   # syntax check, shellcheck if installed, go vet
```

## Keeping up with Mole

`scripts/sync-mole.sh` pulls in new upstream Mole commits:

```sh
scripts/sync-mole.sh --check   # list what Mole changed since the last sync
scripts/sync-mole.sh           # merge it into a new sync/mole-<date> branch
```

Changes to Mole's Go tools (`cmd/`, `internal/`) are merged automatically on a
new branch, then nixit is built and tested; `main` is never touched and
nothing is pushed. If Mole changed lines nixit also changed for Linux, the
script stops with conflict markers; fix them and run
`scripts/sync-mole.sh --finish`. Mole's shell commands were rewritten for Arch,
so changes there are only listed, as ideas to port by hand.

## Credits

- **[Mole](https://github.com/tw93/Mole)** by **[tw93](https://github.com/tw93)**
  and its [contributors](https://github.com/tw93/Mole/graphs/contributors) is
  the project nixit is forked from. Mole's full git history is kept in this
  repository, so every original commit still carries its author.
- What came from Mole: the overall design (one menu for clean, uninstall,
  optimize, analyze, status and purge), the disk analyzer (`cmd/analyze`) and
  the status dashboard (`cmd/status`), ported here from macOS to Linux.
- What is new in nixit: the Linux ports of those two tools, and the clean,
  uninstall, optimize and purge commands, rewritten for pacman, the AUR helpers,
  Flatpak and systemd. See [NOTICE](NOTICE) for the full list of changes.

If nixit is useful to you, consider starring
[Mole](https://github.com/tw93/Mole) too.

## License

nixit is licensed under the GNU General Public License v3.0, the same license
as Mole. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
