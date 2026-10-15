#!/usr/bin/env python3
"""Real Flypy regression against native macOS or the Android reference engine.

Uses temporary dictionaries inside the shared repo, never the user's dictionary.
Prepare macOS with scripts/macos/prepare_native.sh; Android reference with prepare_dev.sh.
"""
import argparse
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time


class Engine:
    def __init__(self, base, work, scheme, machine, log, native=False):
        command = ["bash", str(base / "scripts/run_native_engine.sh"), scheme, str(work)]
        if native:
            command = [str(base / "build/macos/WeTypeNativeEngine"),
                       str(base / ".deps/mac-engine/WeType.app"), str(work), scheme]
        elif machine:
            command = ["orb", "-m", machine] + command
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.read("READY", timeout=30)
        self.command("OPT spans", "OK")

    def read(self, expected=None, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError("engine response timed out")
            block = os.read(self.process.stdout.fileno(), 65536)
            if not block:
                raise AssertionError("engine exited: %s" % self.process.poll())
            self.buffer += block
        line, self.buffer = self.buffer.split(b"\n", 1)
        line = line.decode("utf-8")
        if expected:
            assert line == expected or line.startswith(expected + "\t"), line
        return line

    def command(self, command, expected=None):
        self.process.stdin.write((command + "\n").encode())
        return self.read(expected)

    def candidates(self, keys, allow_empty=False):
        line = self.command("B " + keys)
        if allow_empty and line == "EMPTY":
            return []
        return self.parse(line)

    @staticmethod
    def parse(line):
        assert line.startswith("CAND\t"), line
        return [(int(cover), text) for cover, text in
                (item.split(":", 1) for item in line.split("\t")[1:])]

    def close(self):
        try:
            if self.process.poll() is None:
                self.command("Q", "BYE")
                assert self.process.wait(timeout=10) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.selector.close()
            self.process.stdin.close()
            self.process.stdout.close()


def run(base, machine, native):
    (base / ".deps").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="flypy-test.", dir=base / ".deps") as directory:
        directory = Path(directory)
        with (directory / "engine.log").open("wb") as log:
            engine = Engine(base, directory / "flypy", "flypy", machine, log, native)
            try:
                words = []
                for key in "nihc":
                    words = engine.candidates(key, allow_empty=True)
                assert words[0] == (4, "你好"), words[:5]
                print("PASS incremental nihc → 你好 (4 physical keys)", flush=True)
                engine.command("C", "OK")
                assert engine.candidates("vsgo")[0] == (4, "中国")
                engine.command("S 0", "OK")
                print("PASS vsgo → 中国 and selection", flush=True)
                engine.command("C", "OK")
                assert (4, "世界") in engine.candidates("uijp")
                for keys, text in [("ai", "爱"), ("an", "安"), ("ee", "饿"), ("nv", "女")]:
                    engine.command("C", "OK")
                    words = engine.candidates(keys)
                    assert (2, text) in words, (keys, words[:5])
                print("PASS sh/zh initials, zero initials, ü", flush=True)
                engine.command("C", "OK")
                words = engine.candidates("nihcui" if native else "nihcvsgo")
                partial = next(i for i, item in enumerate(words) if item == (4, "你好"))
                rest = Engine.parse(engine.command("S %d" % partial, "CAND"))
                assert ((2, "是") if native else (4, "中国")) in rest, rest[:5]
                engine.command("S 0", "OK")
                print("PASS partial selection consumes double-pinyin key counts", flush=True)
                engine.command("C", "OK")
                words = engine.candidates("nihc")
                learned = next(i for i, item in enumerate(words) if item == (4, "拟好"))
                engine.command("S %d" % learned, "OK")
                time.sleep(0.5)
                engine.command("C", "OK")
                time.sleep(0.5)
                words = engine.candidates("nihc")
                rank = words.index((4, "拟好"))
                assert rank < learned, (learned, rank)
                print("PASS Flypy selection learning", flush=True)
            finally:
                engine.close()
            engine = Engine(base, directory / "flypy", "flypy", machine, log, native)
            try:
                assert engine.candidates("nihc").index((4, "拟好")) <= rank
                print("PASS Flypy learning persists after restart", flush=True)
            finally:
                engine.close()
            engine = Engine(base, directory / "full", "full", machine, log, native)
            try:
                assert engine.candidates("nihao")[0] == (5, "你好")
                print("PASS full-pinyin mode remains available", flush=True)
            finally:
                engine.close()
        print("E2E_RESULT = PASS", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["native", "orb", "linux"], default="native")
    parser.add_argument("--machine", default="wetype-dev", help="OrbStack machine; empty for ARM64 Linux")
    args = parser.parse_args()
    run(Path(__file__).resolve().parents[1], "" if args.backend == "linux" else args.machine,
        args.backend == "native")
