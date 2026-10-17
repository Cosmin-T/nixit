#!/usr/bin/env bash
# One-time setup for the nixit pacman repo. Run once with sudo, then
# `sudo pacman -S nixit` and future `pacman -Syu` updates just work --
# no manual pacman.conf editing.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: curl -fsSL https://cosmin-t.github.io/nixit/install.sh | sudo bash" >&2
    exit 1
fi

CONF="/etc/pacman.conf"
REPO_URL="https://cosmin-t.github.io/nixit/x86_64"

if grep -qE '^\[nixit\]' "$CONF"; then
    echo "==> nixit repo already in $CONF, skipping"
else
    echo "==> Adding nixit repo to $CONF"
    printf '\n[nixit]\nServer = %s\n' "$REPO_URL" >> "$CONF"
fi

echo "==> Syncing and installing nixit"
pacman -Sy --noconfirm
pacman -S --needed --noconfirm nixit

echo "==> Done. Future updates come through your normal pacman -Syu."
