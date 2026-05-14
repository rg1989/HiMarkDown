#!/usr/bin/env python3
"""Extract DMG mount path from `hdiutil attach -plist` output.

Must stay in sync with the inline Python in tools/install.sh (curl one-liner
cannot depend on this file). tools/verify-install-sh.sh exercises this script
and guards install.sh with regression checks.
"""
from __future__ import annotations

import plistlib
import sys


def mount_point_from_plist_bytes(data: bytes) -> str:
    p = plistlib.loads(data)
    path = ""
    for e in p.get("system-entities", []):
        mp = e.get("mount-point")
        if mp:
            path = mp
    return path


def main() -> None:
    data = sys.stdin.buffer.read()
    print(mount_point_from_plist_bytes(data))


if __name__ == "__main__":
    main()
