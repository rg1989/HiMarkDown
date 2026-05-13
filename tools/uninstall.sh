#!/usr/bin/env bash
# tools/uninstall.sh — clean removal of HiMarkDown
#
# Removes the .app, the saved Settings (UserDefaults), the Recent Files
# list, the per-window outline width preference, and the saved theme.
# Leaves the user's actual Markdown documents untouched.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/tools/uninstall.sh | bash
#   # or after a `git clone`:
#   ./tools/uninstall.sh
#
set -euo pipefail

APP_NAME="HiMarkDown"
BUNDLE_ID="dev.himarkdown.HiMarkDown"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }

DEST_APP="/Applications/${APP_NAME}.app"
if [[ -d "$DEST_APP" ]]; then
    bold "▸ Removing $DEST_APP"
    if [[ -w "/Applications" ]]; then
        rm -rf "$DEST_APP"
    else
        sudo rm -rf "$DEST_APP"
    fi
else
    dim "  $DEST_APP not present (skipping)"
fi

bold "▸ Removing user defaults ($BUNDLE_ID)"
defaults delete "$BUNDLE_ID" 2>/dev/null || dim "  no defaults to remove"

# Group container (sandboxed apps store data here)
GROUP_CONT="$HOME/Library/Containers/$BUNDLE_ID"
if [[ -d "$GROUP_CONT" ]]; then
    bold "▸ Removing sandbox container $GROUP_CONT"
    rm -rf "$GROUP_CONT"
fi

green "✓ Uninstalled ${APP_NAME}. Your Markdown files were not touched."
