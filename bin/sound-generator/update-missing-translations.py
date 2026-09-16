#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bring every language list in json/ into line with the English one.

en.json is the master: it decides which files exist. Running this after adding a line there
gives every other language the same entry with an empty translation and `needs_translation`
set, so nothing is silently left English. Existing translations are kept untouched.

The lists are written back sorted by file name and with a fixed indent, so that a change to one
line produces a one-line diff rather than a reordering.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
JSON_DIR = os.path.join(HERE, "json")


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save(path, data):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    master_path = os.path.join(JSON_DIR, "en.json")
    if not os.path.exists(master_path):
        print("No en.json in %s" % JSON_DIR, file=sys.stderr)
        return 1

    master = sorted(load(master_path), key=lambda e: e["file"])
    save(master_path, master)
    print("en.json: %d entries" % len(master))

    for name in sorted(os.listdir(JSON_DIR)):
        if not name.endswith(".json") or name == "en.json":
            continue
        path = os.path.join(JSON_DIR, name)
        existing = {e["file"]: e for e in load(path)}

        merged = []
        for entry in master:
            kept = existing.get(entry["file"])
            translation = kept.get("translation") if kept else None
            merged.append({
                "file": entry["file"],
                "english": entry["english"],
                "translation": translation,
                "needs_translation": translation is None,
            })

        dropped = sorted(set(existing) - set(e["file"] for e in master))
        save(path, merged)
        print("%s: %d entries, %d untranslated%s"
              % (name, len(merged), sum(1 for e in merged if e["needs_translation"]),
                 ", %d dropped (%s)" % (len(dropped), ", ".join(dropped)) if dropped else ""))

    return 0


if __name__ == "__main__":
    sys.exit(main())
