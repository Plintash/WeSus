#!/usr/bin/env python3
"""Check packaged icons and round-trip the actual macOS backup format."""

import hashlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import archive_app


BASE = Path(__file__).resolve().parents[2]


class InstallationTests(unittest.TestCase):
    def test_packaged_icons(self):
        app = BASE / "build/macos/WeTypeIME.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        resources = app / "Contents/Resources"
        icon = info["CFBundleIconFile"]
        revision = hashlib.sha256((BASE / 'macos/Tools/GenerateInputSourceIcon.swift').read_bytes()
                                  + (resources / icon).read_bytes()).hexdigest()[:12]
        self.assertEqual(icon, f"WeSus-{revision}.icns")
        menu = f"WeSusMenuTemplate-{revision}.pdf"
        modes = info["ComponentInputModeDict"]["tsInputModeListKey"]
        for mode in modes.values():
            for key in ["tsInputModeMenuIconFileKey", "tsInputModeAlternateMenuIconFileKey",
                        "tsInputModePaletteIconFileKey"]:
                self.assertEqual(mode[key], menu)
        for key in ["tsInputMethodIconFileKey", "tsInputMethodAlternateIconFileKey"]:
            self.assertEqual(info[key], menu)
        self.assertTrue((resources / menu).is_file())
        self.assertEqual({p.name for p in resources.iterdir() if p.suffix in {".pdf", ".icns"}},
                         {icon, menu}, "Old artwork leaked into the app bundle")
        self.assertGreaterEqual(int(info["CFBundleVersion"]), 3)

    def test_backups_are_restorable_and_unrelated_files_survive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            backups = root / "AppBackups"
            backups.mkdir()
            app = root / "WeTypeIME.app"
            old = backups / "WeTypeIME.app.previous.1"
            for bundle in [app, old]:
                contents = bundle / "Contents"
                contents.mkdir(parents=True)
                (contents / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "io.github.plintash.inputmethod.wetype"}))
                (contents / "artwork").write_bytes(b"original icon bytes")
            unrelated = backups / "unrelated.app"
            unrelated.mkdir()
            run = subprocess.run

            def archive_command(args, **kwargs):
                if args[0] == archive_app.LSREGISTER:
                    # Reproduce lsregister's response for an unregistered old backup.
                    return subprocess.CompletedProcess(args, 1, stdout="failed to scan: -10814", stderr="")
                return run(args, **kwargs)

            with patch.object(sys, "argv", ["archive_app.py", str(backups), str(app)]), \
                    patch.object(archive_app.subprocess, "run", side_effect=archive_command):
                archive_app.main()
            self.assertFalse(app.exists())
            self.assertFalse(old.exists())
            self.assertTrue(unrelated.exists())
            archives = list(backups.glob("*.zip"))
            self.assertEqual(len(archives), 2)
            restored = root / "restored"
            for archive in archives:
                run(["ditto", "-x", "-k", str(archive), str(restored)], check=True)
            for name in [app.name, old.name]:
                self.assertEqual((restored / name / "Contents/artwork").read_bytes(), b"original icon bytes")

    def test_failed_archive_keeps_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "WeTypeIME.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "io.github.plintash.inputmethod.wetype"}))
            with patch.object(archive_app.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "ditto")):
                with self.assertRaises(subprocess.CalledProcessError):
                    archive_app.archive_app(app, root)
            self.assertTrue(app.exists())
            self.assertFalse(list(root.glob("*.zip")))


if __name__ == "__main__":
    unittest.main()
