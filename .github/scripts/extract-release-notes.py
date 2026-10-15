#!/usr/bin/env python3
"""Extract release notes for a given version from Releases.md with a length cap.

GitHub release bodies are capped at 125,000 characters. When hundreds of PRs
accumulate under one release, the raw changelog can exceed that limit and cause
`gh release create` to fail with HTTP 422.

This script extracts the section for the requested version, bounds the output
to MAX_CHARS, cuts cleanly at line boundaries, and appends a truncation notice
linking back to Releases.md when truncation occurs.
"""

import argparse
import sys

DEFAULT_MAX_CHARS = 120000

TRUNCATION_NOTICE = (
    "\n\n---\n"
    "> [!NOTE]\n"
    "> Release notes truncated to fit GitHub's 125,000 character release body limit.\n"
    "> See [Releases.md](https://github.com/rotorflight/rotorflight-lua-edgetx-suite/blob/master/Releases.md) for the full changelog.\n"
)


def extract_release_notes(release, inputfile, max_chars=DEFAULT_MAX_CHARS):
    """Extract release notes lines for `release` from `inputfile` bounded to `max_chars`."""
    found = False
    collected = []

    with open(inputfile, "r", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("# "):
                if found:
                    break
                found = line.strip() == "# " + release
            elif line.startswith("***"):
                found = False
            elif found:
                collected.append(line)

    total_len = sum(len(l) for l in collected)
    if total_len <= max_chars:
        return "".join(collected)

    target_len = max(0, max_chars - len(TRUNCATION_NOTICE))
    out_lines = []
    curr_len = 0
    for line in collected:
        if curr_len + len(line) > target_len:
            break
        out_lines.append(line)
        curr_len += len(line)

    prefix = "".join(out_lines).rstrip()
    if prefix:
        full = prefix + TRUNCATION_NOTICE
    else:
        full = TRUNCATION_NOTICE.lstrip()

    if len(full) > max_chars:
        full = full[:max_chars]
    return full


def self_test():
    """Run regression tests against short, long, and multi-version fixtures."""
    import tempfile

    # Build a long fixture so that total_len exceeds max_chars, but max_chars is large
    # enough to hold several lines before the truncation notice.
    fixture_lines = ["# 0.2.0\n"] + [f"Release note item {i:03d}\n" for i in range(100)] + ["# 0.1.6\n", "old line\n"]
    fixture = "".join(fixture_lines)

    with tempfile.NamedTemporaryFile("w+", encoding="utf-8", delete=False) as tf:
        tf.write(fixture)
        temp_name = tf.name

    try:
        # 1. Exact extraction without truncation
        res = extract_release_notes("0.1.6", temp_name, max_chars=100)
        assert res == "old line\n", f"Unexpected output: {res!r}"

        # 2. Truncation when exceeding max_chars
        # Item lines are 23 chars each. 100 items = 2300 chars. Set cap to 500.
        res_trunc = extract_release_notes("0.2.0", temp_name, max_chars=500)
        assert "Release notes truncated" in res_trunc, "Expected truncation notice"
        assert res_trunc.startswith("Release note item 000\n"), f"Unexpected start: {res_trunc!r}"
        assert len(res_trunc) <= 500, f"Length cap exceeded: {len(res_trunc)}"

        # 3. Unknown version returns empty string
        res_none = extract_release_notes("9.9.9", temp_name, max_chars=100)
        assert res_none == "", f"Expected empty, got: {res_none!r}"
    finally:
        import os
        try:
            os.remove(temp_name)
        except OSError:
            pass

    print("All extract_release_notes self-tests passed.")
    return 0


def main(argv=None):
    if argv is None:
        argv = sys.argv

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", nargs="?", help="Release version string, e.g. 0.2.0")
    parser.add_argument("inputfile", nargs="?", help="Path to Releases.md")
    parser.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS,
                        help="Maximum characters to emit (default: 120000)")
    parser.add_argument("--self-test", action="store_true", help="Run self-tests and exit")

    args = parser.parse_args(argv[1:])

    if args.self_test:
        return self_test()

    if not args.release or not args.inputfile:
        parser.error("release and inputfile are required unless --self-test is given")

    notes = extract_release_notes(args.release, args.inputfile, max_chars=args.max_chars)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.stdout.write(notes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
