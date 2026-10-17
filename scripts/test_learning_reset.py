#!/usr/bin/env python3
"""Exercise targeted learning reset with temporary native dictionaries only."""
from pathlib import Path
import base64
import json
import tempfile
import time

from test_flypy import Engine


def run(base, scheme):
    with tempfile.TemporaryDirectory(prefix="learning-reset.", dir=base / ".deps") as temporary:
        root = Path(temporary)
        with (root / "engine.log").open("wb") as log:
            engine = Engine(base, root / "dictionary", scheme, "", log, native=True)

            def candidates(keys):
                engine.command("C", "OK")
                return engine.candidates(keys)

            def learn(keys, word):
                words = candidates(keys)
                index = next(i for i, (_, text) in enumerate(words) if text == word)
                engine.command("S %d" % index, "OK")
                time.sleep(0.5)

            def learned():
                engine.command("C", "OK")
                line = engine.command("LEARNING", "LEARNED")
                return json.loads(base64.b64decode(line.split("\t", 1)[1]))

            hello = "nihc" if scheme == "flypy" else "nihao"
            try:
                assert learned() == []
                original_he = candidates("he")
                original_phrase = candidates(hello)
                for _ in range(2):
                    learn("he", "鹤")
                    learn(hello, "拟好")
                assert candidates("he")[0][1] == "鹤"
                learned_phrase = candidates(hello)
                assert learned_phrase.index((len(hello), "拟好")) < original_phrase.index((len(hello), "拟好"))
                records = learned()
                crane = next(row for row in records if row["word"] == "鹤")
                assert crane["pinyin"] == "he" and crane["count"] == 2 and crane["currentRank"] == 1
                assert 1.8 < crane["heat"] <= 2 and crane["historyHeat"] > 0 and crane["lastUsed"] > 0
                assert next(row for row in records if row["word"] == "拟好")["pinyin"] == "ni'hao"
                baseline = Engine(base, root / "baseline", "full", "", log, native=True)
                try:
                    payload = base64.b64encode(json.dumps(records).encode()).decode()
                    line = baseline.command("RANKS\t" + payload, "RANKED")
                    ranks = json.loads(base64.b64decode(line.split("\t", 1)[1]))
                    assert next(row for row in ranks if row["word"] == "鹤")["currentRank"] == 10
                    assert next(row for row in ranks if row["word"] == "拟好")["currentRank"] > 1
                finally:
                    baseline.close()
                assert candidates("he")[0][1] == "鹤"
                assert next(row for row in learned() if row["word"] == "鹤")["count"] == 2
                print("PASS real learned-word counters, heat, readings and independent baseline ranks", flush=True)

                engine.command("C", "OK")
                # This is the exact settings protocol, not the research helper.
                engine.command("FORGET\the\t鹤", "OK")
                assert candidates("he") == original_he
                assert candidates(hello) == learned_phrase
                assert all(row["word"] != "鹤" for row in learned())
                print("PASS %s single-character reset preserves learned phrase" % scheme, flush=True)

                engine.command("C", "OK")
                engine.command("FORGET\tni'hao\t拟好", "OK")
                assert candidates(hello) == original_phrase
                print("PASS %s phrase reset" % scheme, flush=True)

                # Reject malformed and active-composition requests before any write.
                for command in ["FORGET\t\t鹤", "FORGET\the\t", "FORGET\t../he\t鹤",
                                "FORGET\t'he\t鹤", "FORGET\the''hao\t鹤", "FORGET\the\t鹤\textra"]:
                    engine.command("C", "OK")
                    engine.command(command, "ERR")
                engine.candidates("he")
                engine.command("FORGET\the\t鹤", "ERR_BUSY")
                assert candidates("he") == original_he
                print("PASS invalid and busy resets are rejected", flush=True)
            finally:
                engine.close()

            engine = Engine(base, root / "dictionary", scheme, "", log, native=True)
            try:
                assert candidates("he") == original_he
                assert candidates(hello) == original_phrase
                print("PASS %s resets persist after restart" % scheme, flush=True)
                for _ in range(2):
                    learn("he", "喝")
                    learn("he", "鹤")
                engine.command("C", "OK")
                engine.command("FORGET\the\t鹤", "OK")
                assert candidates("he")[0][1] == "喝"
                assert candidates("he").index((2, "鹤")) >= 9
                print("PASS reset preserves another learned word with the same pinyin", flush=True)

                if scheme == "full":
                    original_chong = candidates("chong")
                    for _ in range(3):
                        learn("chong", "重")
                        learn("zhong", "重")
                    learned_zhong = candidates("zhong")
                    assert learned_zhong[0][1] == "重"
                    engine.command("C", "OK")
                    engine.command("FORGET\tchong\t重", "OK")
                    assert candidates("chong") == original_chong
                    assert candidates("zhong") == learned_zhong
                    print("PASS reset preserves the same character under another reading", flush=True)
            finally:
                engine.close()


if __name__ == "__main__":
    base = Path(__file__).resolve().parents[1]
    for scheme in ["flypy", "full"]:
        run(base, scheme)
