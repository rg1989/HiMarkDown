#!/usr/bin/env bash
# Run locally or in CI: bash tools/verify-install-sh.sh
# Guards tools/install.sh (syntax, shellcheck, DMG mount plist parsing, regressions).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT/tools/install.sh"
PY="$ROOT/tools/install_mountpoint_from_plist.py"
FIXTURE="$ROOT/tools/fixtures/hdiutil-attach-sample.plist"

echo "▸ bash -n tools/install.sh"
bash -n "$INSTALL_SH"

if command -v shellcheck >/dev/null 2>&1; then
  echo "▸ shellcheck tools/install.sh"
  shellcheck "$INSTALL_SH"
else
  echo "▸ shellcheck not installed — skipping (install: brew install shellcheck)"
fi

echo "▸ mount path from plist fixture (python module, stdin pipe)"
MP="$(cat "$FIXTURE" | python3 "$PY")"
if [[ "$MP" != "/Volumes/HiMarkDown 1.0" ]]; then
  echo "✗ expected /Volumes/HiMarkDown 1.0, got: $MP" >&2
  exit 1
fi

echo "▸ install.sh still uses plistlib.loads (non-seekable stdin) for mount parsing"
if ! grep -q "plistlib.loads(sys.stdin.buffer.read())" "$INSTALL_SH"; then
  echo "✗ install.sh missing plistlib.loads(stdin.read()) — sync with tools/install_mountpoint_from_plist.py" >&2
  exit 1
fi

echo "▸ install.sh must not regress to awk-only mount parsing"
if grep -E "MOUNT_POINT=.*print \$NF" "$INSTALL_SH"; then
  echo "✗ install.sh still uses awk \\$NF for mount point (breaks spaces in volume names)" >&2
  exit 1
fi

echo "✓ verify-install-sh OK"
