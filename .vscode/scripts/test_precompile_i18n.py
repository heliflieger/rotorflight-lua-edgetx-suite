"""Regression test for precompile_i18n.py.

    python .vscode/scripts/test_precompile_i18n.py
    python .vscode/scripts/test_precompile_i18n.py --self-test

The plain run precompiles one fixture page and compares the result with the output
this script expects. The self-test run feeds the same checks the output an earlier
precompiler produced, and fails unless they reject it: a check that cannot go red
says nothing when it is green.

The fixture carries both translation forms in one page, because that is what the
regressions in it look like. A page-local pageText/t call must keep resolving against
the page's own key block, and a cross-page Common.t call must resolve against the
block it names -- without the generic pattern matching the "t(" inside "Common.t("
first, which used to leave a name followed by a string literal behind.
"""

import argparse
import difflib
import importlib.util
import re
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).with_name("precompile_i18n.py")

FIXTURE = """\
local Common = assert(loadScript("/scripts/rfsuite/app/pages/settings/common.lua"))()
Common.pageT("setup_wizard")

local a = Common.t(i18n, "setup_ports", "function_esc_sensor", "ESC Sensor")
local b = Common.t(i18n, "setup_ports", "function_esc_sensor")
local c = pageText(i18n, "own_key", "Own Fallback")
local d = t(i18n, "plain_key", "Plain Fallback")
"""

EXPECTED = """\
local Common = assert(loadScript("/scripts/rfsuite/app/pages/settings/common.lua"))()
Common.pageT("setup_wizard")

local a = "@i18n(app.pages.setup_ports.function_esc_sensor|ESC Sensor)@"
local b = "@i18n(app.pages.setup_ports.function_esc_sensor)@"
local c = "@i18n(app.pages.setup_wizard.own_key|Own Fallback)@"
local d = "@i18n(app.pages.setup_wizard.plain_key|Plain Fallback)@"
"""

# What the precompiler emitted for the same fixture while the generic pageText/t
# pattern still began with a word boundary: the match started at the "t(" inside
# "Common.t(", the page key was taken for the key, and the optional fallback group
# swallowed the rest of the argument list. Lines a and b are not untranslated
# strings, they are syntax errors -- luac -p reports <name> expected. This is the
# red control the self-test runs the checks against.
REGRESSED = """\
local Common = assert(loadScript("/scripts/rfsuite/app/pages/settings/common.lua"))()
Common.pageT("setup_wizard")

local a = Common."@i18n(app.pages.setup_wizard.setup_ports|function_esc_sensor"__COMMA__ "ESC Sensor)@"
local b = Common."@i18n(app.pages.setup_wizard.setup_ports|function_esc_sensor)@"
local c = "@i18n(app.pages.setup_wizard.own_key|Own Fallback)@"
local d = "@i18n(app.pages.setup_wizard.plain_key|Plain Fallback)@"
"""

# A marker that has replaced the call part of a qualified name leaves the name and a
# string literal side by side, which no Lua parser accepts.
QUALIFIED_MARKER = re.compile(r'[A-Za-z0-9_\]]\s*\.\s*"@i18n')


def check(output):
    """Return the problems in one precompiled page; an empty list means it passed."""
    problems = []

    if output != EXPECTED:
        diff = difflib.unified_diff(
            EXPECTED.splitlines(), output.splitlines(),
            fromfile="expected", tofile="precompiled", lineterm="")
        problems.append("the precompiled page does not match the expected one\n"
                        + "\n".join(diff))

    for number, line in enumerate(output.splitlines(), 1):
        if QUALIFIED_MARKER.search(line):
            problems.append("line %d is not valid Lua -- a marker replaced the call "
                            "part of a qualified name: %s" % (number, line.strip()))

    return problems


def precompile(source):
    """Run the precompiler over one page and return what it wrote."""
    spec = importlib.util.spec_from_file_location("precompile_i18n", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    with tempfile.TemporaryDirectory() as staging:
        page = Path(staging) / "page.lua"
        page.write_text(source, encoding="utf-8")
        module.process_file(page)
        return page.read_text(encoding="utf-8")


def self_test():
    """Prove the checks can go red, and that they pass on the output they describe."""
    if check(EXPECTED):
        print("FAIL: the checks reject the output they are written against")
        return 1

    problems = check(REGRESSED)
    if not problems:
        print("FAIL: the checks accept a page that does not compile")
        return 1

    print("self-test ok: %d problem(s) reported for the earlier output, "
          "none for the expected one" % len(problems))
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Precompile one fixture page and check the result.")
    parser.add_argument("--self-test", action="store_true",
                        help="prove the checks can go red, and change nothing else")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    problems = check(precompile(FIXTURE))
    if problems:
        for problem in problems:
            print(problem)
        return 1

    print("ok: the page-local and the cross-page form both resolve, "
          "and the page compiles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
