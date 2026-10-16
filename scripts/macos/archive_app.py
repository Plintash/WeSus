#!/usr/bin/env python3
"""Keep recoverable app backups without leaving duplicate bundles discoverable."""

import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


BUNDLE_IDS = {"io.github.plintash.inputmethod.wetype", "io.github.plintash.wetype-ime"}
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def owned_app(path):
    try:
        info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
        return info.get("CFBundleIdentifier") in BUNDLE_IDS
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False


def archive_app(app, backups):
    if app.is_symlink() or not owned_app(app):
        raise SystemExit(f"Refusing to archive an unrelated app: {app}")
    # Only remove the bundle after a complete archive exists. ditto preserves
    # macOS metadata, resource forks and the bundle's top-level directory.
    with tempfile.TemporaryDirectory(prefix=".archive-", dir=backups) as staging:
        archive = Path(staging) / "backup.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(app), str(archive)], check=True)
        destination = backups / f"{app.name}.{time.time_ns()}.zip"
        archive.rename(destination)
    result = subprocess.run([LSREGISTER, "-u", str(app)], capture_output=True, text=True)
    if result.returncode:
        detail = (result.stdout or "") + (result.stderr or "")
        # Older .app.previous backups may never have been registered (or may
        # no longer be recognized as apps). There is nothing to unregister.
        if not re.search(r"(?<!\d)-(10814|10811)(?!\d)", detail):
            raise RuntimeError(f"Could not unregister {app}: {detail.strip()}")
    shutil.rmtree(app)
    print(f"Archived: {destination}")


def main():
    backups, app = map(Path, sys.argv[1:])
    # Check the install destination before migrating any previous backups.
    if app.exists() and (app.is_symlink() or not owned_app(app)):
        raise SystemExit(f"An unrelated app already exists at {app}")
    backups.mkdir(parents=True, exist_ok=True)
    for old in sorted(backups.iterdir()):
        if old.is_dir() and not old.is_symlink() and owned_app(old):
            archive_app(old, backups)
    if app.exists():
        archive_app(app, backups)


if __name__ == "__main__":
    main()
