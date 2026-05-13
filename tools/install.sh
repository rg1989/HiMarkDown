#!/usr/bin/env bash
# tools/install.sh — one-line installer for HiMarkDown
#
# Usage (from anywhere):
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/tools/install.sh | bash
#
# The script:
#   1. Asks GitHub for the latest release of <owner>/<repo>
#   2. Downloads the .dmg, verifies its SHA256 against the release manifest
#   3. Mounts the DMG, copies HiMarkDown.app to /Applications
#   4. Removes the macOS quarantine flag so the app launches without a
#      Gatekeeper prompt
#   5. Cleans up the mount and the temp download
#
# Why the quarantine removal? The app is ad-hoc signed (no paid Apple
# Developer ID yet), so without this step macOS would otherwise show a
# "cannot verify the developer" dialog. The user is opting in to install
# by running this script, so we strip the quarantine for them — the same
# thing Homebrew Cask does for unsigned/ad-hoc casks.
#
set -euo pipefail

# ── Edit these two lines if you fork ─────────────────────────────────────
GITHUB_OWNER="${HIMD_OWNER:-OWNER_PLACEHOLDER}"
GITHUB_REPO="${HIMD_REPO:-REPO_PLACEHOLDER}"
APP_NAME="HiMarkDown"
INSTALL_DIR="${HIMD_INSTALL_DIR:-/Applications}"

API_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    red "✗ HiMarkDown is macOS-only. Aborting."
    exit 1
fi

bold "▸ Asking GitHub for the latest ${APP_NAME} release…"
META_JSON="$(curl -fsSL "$API_URL")" || {
    red "✗ Could not reach $API_URL"
    red "  Check your network connection or set HIMD_OWNER / HIMD_REPO env vars."
    exit 1
}

VERSION_TAG="$(printf '%s' "$META_JSON" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["tag_name"])
')"
DMG_URL="$(printf '%s' "$META_JSON" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data["assets"]:
    if a["name"].endswith(".dmg"):
        print(a["browser_download_url"])
        break
')"
SHA_URL="$(printf '%s' "$META_JSON" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data["assets"]:
    if a["name"].endswith(".sha256"):
        print(a["browser_download_url"])
        break
')"

if [[ -z "$DMG_URL" ]]; then
    red "✗ No .dmg asset found in the latest release ($VERSION_TAG)."
    exit 1
fi

dim "  version : $VERSION_TAG"
dim "  dmg url : $DMG_URL"

TMP_DIR="$(mktemp -d -t himarkdown-install)"
trap 'rm -rf "$TMP_DIR"' EXIT
DMG_PATH="$TMP_DIR/${APP_NAME}.dmg"

bold "▸ Downloading…"
curl -fL --progress-bar -o "$DMG_PATH" "$DMG_URL"

if [[ -n "$SHA_URL" ]]; then
    bold "▸ Verifying SHA256 against the release manifest…"
    SHA_PATH="$TMP_DIR/checksums.sha256"
    curl -fsSL -o "$SHA_PATH" "$SHA_URL"
    EXPECTED="$(grep -E '\.dmg$' "$SHA_PATH" | awk '{print $1}' | head -n1)"
    ACTUAL="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        red "✗ Checksum mismatch!"
        red "  expected $EXPECTED"
        red "  got      $ACTUAL"
        exit 1
    fi
    green "  ✓ Checksum OK"
else
    dim "  (no .sha256 manifest in this release — skipping verification)"
fi

bold "▸ Mounting DMG…"
MOUNT_OUT="$(hdiutil attach -nobrowse -noverify -noautoopen "$DMG_PATH")"
MOUNT_POINT="$(printf '%s' "$MOUNT_OUT" | tail -n1 | awk '{print $NF}')"
dim "  mounted at $MOUNT_POINT"

cleanup_mount() {
    if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
        hdiutil detach -quiet "$MOUNT_POINT" || true
    fi
}
trap 'cleanup_mount; rm -rf "$TMP_DIR"' EXIT

SRC_APP="$MOUNT_POINT/${APP_NAME}.app"
if [[ ! -d "$SRC_APP" ]]; then
    red "✗ ${APP_NAME}.app not found at $SRC_APP"
    exit 1
fi

DEST_APP="$INSTALL_DIR/${APP_NAME}.app"
if [[ -d "$DEST_APP" ]]; then
    bold "▸ Removing previous installation at $DEST_APP…"
    if [[ -w "$INSTALL_DIR" ]]; then
        rm -rf "$DEST_APP"
    else
        sudo rm -rf "$DEST_APP"
    fi
fi

bold "▸ Copying ${APP_NAME}.app to $INSTALL_DIR…"
if [[ -w "$INSTALL_DIR" ]]; then
    cp -R "$SRC_APP" "$INSTALL_DIR/"
else
    sudo cp -R "$SRC_APP" "$INSTALL_DIR/"
fi

bold "▸ Removing quarantine flag (so you don't see the Gatekeeper prompt)…"
if [[ -w "$DEST_APP" ]]; then
    xattr -dr com.apple.quarantine "$DEST_APP" || true
else
    sudo xattr -dr com.apple.quarantine "$DEST_APP" || true
fi

green "✓ Installed ${APP_NAME} ${VERSION_TAG} → $DEST_APP"
echo
bold "Launch it with:  open -a ${APP_NAME}"
