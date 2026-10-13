# nixit

**Clean and tune your Arch system from the terminal.**

nixit is a Linux fork of [Mole](https://github.com/tw93/Mole), the macOS
cleaner by tw93, rebuilt for Arch Linux and CachyOS. It frees disk space,
removes apps with their leftovers, runs routine maintenance, shows what is
eating your disk and gives you a live system dashboard, all from one menu.

nixit is an independent project. It is not affiliated with or endorsed by Mole
or its authors.

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

Needs `bash`, `fzf`, `pacman-contrib` (for `paccache`) and `go` to build.

```sh
sudo pacman -S --needed fzf pacman-contrib go
git clone https://github.com/Cosmin-T/nixit.git ~/Projects/nixit
cd ~/Projects/nixit
make install        # builds the Go tools, links ~/.local/bin/nixit
```

Update later with `nixit update`. Remove with `make uninstall`.

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

## License and credits

nixit is licensed under the GNU General Public License v3.0, the same license
as Mole. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The disk analyzer and status dashboard are adapted from Mole's Go code; the
shell commands were rewritten for Arch. Thanks to tw93 and the Mole
contributors for the original project.
