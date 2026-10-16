#!/usr/bin/env python3
"""Refresh this user's system input UI after updating input-source artwork."""

import os
import signal
import subprocess
import time
from pathlib import Path


SERVICES = {
    "/System/Library/CoreServices/TextInputSwitcher.app/Contents/MacOS/TextInputSwitcher",
    "/System/Library/CoreServices/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent",
    "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
}


def processes():
    output = subprocess.run(["ps", "-axo", "uid=,pid=,comm="],
                            capture_output=True, text=True, check=True).stdout
    result = {}
    for line in output.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) == 3:
            uid, pid, command = fields
            if int(uid) == os.getuid() and command in SERVICES:
                result[int(pid)] = command
    return result


def refresh():
    targets = processes()
    if not targets:
        print("System input UI is not running; it will load fresh icons on demand.")
        return
    for pid in targets:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not targets.keys() & processes().keys():
            break
        time.sleep(0.1)
    # Some versions keep the switcher alive after SIGTERM. Check the executable
    # again before forcing exit, including in the unlikely event of PID reuse.
    current = processes()
    for pid, command in targets.items():
        if current.get(pid) == command:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    print("Refreshed system input UI: " + ", ".join(sorted({Path(p).name for p in targets.values()})))
    print("These services restart on demand; the input method itself remains running.")


if __name__ == "__main__":
    refresh()
