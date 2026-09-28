#!/usr/bin/env python3
"""
Per-locale Radio Install ZIP builder for Rotorflight EdgeTX Suite.
Used in GitHub Actions CI (pr/push/release/snapshot workflows) and local
packaging via package.cmd / package.sh.
"""

import argparse
import hashlib
import os
import sys
import shutil
import zipfile
import tempfile
import re
import subprocess

WORKSPACE_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def get_suite_version():
    ver_file = os.path.join(WORKSPACE_ROOT, "src", "rfsuite", "lib", "version.lua")
    if os.path.isfile(ver_file):
        with open(ver_file, "r", encoding="utf-8") as f:
            content = f.read()
        m_maj = re.search(r"M\.MAJOR\s*=\s*(\d+)", content)
        m_min = re.search(r"M\.MINOR\s*=\s*(\d+)", content)
        m_pat = re.search(r"M\.PATCH\s*=\s*(\d+)", content)
        if m_maj and m_min and m_pat:
            return f"{m_maj.group(1)}.{m_min.group(1)}.{m_pat.group(1)}"
    return "0.1.0"


def get_available_languages():
    i18n_dir = os.path.join(WORKSPACE_ROOT, "src", "rfsuite", "i18n")
    langs = []
    if os.path.isdir(i18n_dir):
        for f in os.listdir(i18n_dir):
            if f.endswith(".lua") and f != "init.lua":
                langs.append(f[:-4])
    return langs if langs else ["en"]


# The same extensions resolve_i18n_tags.py walks, so a marker count taken here is
# comparable with what the resolver was able to reach.
I18N_MARKER_EXTS = ('.lua', '.ts', '.tsx', '.js', '.jsx', '.json', '.md', '.txt')
I18N_MARKER = "@i18n("


def count_i18n_markers(roots):
    """Count the literal @i18n( markers standing in the staged tree.

    The *resolver* only ever takes markers away; the precompiler is what adds
    them, and it runs before this. So the count to compare is "markers the
    resolver left standing" against "markers the resolver was able to reach",
    and it is the second that the resolver's own refusal message quotes (2863 of
    551). Taking it on both sides of the stage is what catches a run in which
    every write failed: from out here that looks exactly like a stage that
    resolved nothing.
    """
    total = 0
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            for name in files:
                if not name.lower().endswith(I18N_MARKER_EXTS):
                    continue
                try:
                    with open(os.path.join(dirpath, name), "r",
                              encoding="utf-8", errors="replace") as fh:
                        total += fh.read().count(I18N_MARKER)
                except OSError as e:
                    raise RuntimeError(
                        f"cannot read staged file while counting i18n markers: {dirpath}/{name}: {e}"
                    ) from e
    return total


PAGE_ID_RE = re.compile(r"^[a-z0-9_]+$")
PAGE_ENTRY_RE = re.compile(r"\{([^{}]*)\}")


def parse_theme_pages(content):
    """The optional `pages` list a theme declares in its init.lua.

    A theme may split its settings page into pages, and a radio without directory enumeration
    reads them out of the generated theme index rather than out of init.lua, so the packager
    has to carry them across. init.lua is read as text here rather than executed, exactly as
    the keys above it are; the list is found by its key and taken by brace balance, and each
    entry is validated the way the runtime validates it -- a page id becomes part of a menu id,
    a title is what the tile reads, and an entry missing either is dropped rather than fatal.
    """
    key = re.search(r"\bpages\s*=\s*\{", content)
    if not key:
        return []

    start = key.end() - 1
    depth = 0
    end = None
    for i in range(start, len(content)):
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        return []

    pages = []
    seen = set()
    for entry in PAGE_ENTRY_RE.finditer(content[start + 1:end]):
        body = entry.group(1)
        id_m = re.search(r'\bid\s*=\s*"([^"]*)"', body)
        title_m = re.search(r'\btitle\s*=\s*"([^"]*)"', body)
        if not id_m or not title_m or not title_m.group(1):
            continue
        page_id = id_m.group(1)
        if not PAGE_ID_RE.match(page_id) or page_id in seen:
            continue
        seen.add(page_id)
        icon_m = re.search(r'\bicon\s*=\s*"([^"]+)"', body)
        pages.append({
            "id": page_id,
            "title": title_m.group(1),
            "icon": icon_m.group(1) if icon_m else None
        })
    return pages


def get_theme_metadata(theme_dir, source_name):
    init_file = os.path.join(theme_dir, "init.lua")
    if not os.path.isfile(init_file):
        return None
    with open(init_file, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()
    name_m = re.search(r'name\s*=\s*"([^"]+)"', content)
    if not name_m:
        return None
    config_m = re.search(r'configure\s*=\s*"([^"]+)"', content)
    stand_m = re.search(r"standalone\s*=\s*(true|false)", content)
    return {
        "name": name_m.group(1),
        "source": source_name,
        "folder": os.path.basename(theme_dir),
        "configure": config_m.group(1) if config_m else None,
        "standalone": stand_m.group(1) == "true" if stand_m else False,
        "pages": parse_theme_pages(content)
    }


def lua_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def lua_pages_table(pages):
    """The `pages` list as an index row carries it. A theme without pages adds nothing."""
    if not pages:
        return ""
    items = []
    for page in pages:
        icon = f', icon = "{lua_escape(page["icon"])}"' if page.get("icon") else ""
        items.append(f'{{ id = "{lua_escape(page["id"])}", title = "{lua_escape(page["title"])}"{icon} }}')
    return ", pages = { " + ", ".join(items) + " }"


def generate_theme_index(target_core_dir, target_user_dir):
    entries = []
    sys_themes = os.path.join(target_core_dir, "widgets", "dashboard", "themes")
    if os.path.isdir(sys_themes):
        for d in os.listdir(sys_themes):
            full_d = os.path.join(sys_themes, d)
            if os.path.isdir(full_d):
                meta = get_theme_metadata(full_d, "system")
                if meta:
                    entries.append(meta)

    user_themes = os.path.join(target_user_dir, "dashboard")
    if os.path.isdir(user_themes):
        for d in os.listdir(user_themes):
            full_d = os.path.join(user_themes, d)
            if os.path.isdir(full_d):
                meta = get_theme_metadata(full_d, "user")
                if meta:
                    entries.append(meta)

    out_file = os.path.join(target_core_dir, "app", "pages", "settings", "dashboard", "theme_index.lua")
    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    lines = ["return {"]
    for e in entries:
        safe_name = lua_escape(e["name"])
        safe_folder = lua_escape(e["folder"])
        cfg_val = f'"{e["configure"]}"' if e["configure"] else "nil"
        stand_val = "true" if e["standalone"] else "false"
        pages_val = lua_pages_table(e.get("pages"))
        lines.append(f'  {{ name = "{safe_name}", source = "{e["source"]}", folder = "{safe_folder}", '
                     f'configure = {cfg_val}, standalone = {stand_val}{pages_val} }},')
    lines.append("}\n")
    with open(out_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def write_build_identity(staging_root, staging_core, version):
    """Record what this package is, for the compile pass on the radio to compare against.

    lib/precompile.lua keeps a stamp of the tree it last compiled and rebuilds everything when
    that stamp changes, because a source arriving with an older timestamp than the bytecode of
    the install it replaces would otherwise keep running the old bytecode. The version number
    is too coarse to serve as that stamp: two packages can carry the same one and different
    sources -- a development build, a re-cut candidate, the other locale, which differs
    wherever a translation was resolved into a source. A digest over the packaged sources
    carries the same information and changes whenever they do, while an unchanged package
    still produces an unchanged identity and so costs a reinstall nothing.
    """
    digest = hashlib.sha256()
    for root, dirs, files in os.walk(staging_root):
        dirs.sort()
        for name in sorted(files):
            if not name.endswith(".lua"):
                continue
            full_p = os.path.join(root, name)
            rel_p = os.path.relpath(full_p, staging_root).replace(os.sep, "/")
            digest.update(rel_p.encode("utf-8"))
            digest.update(b"\0")
            with open(full_p, "rb") as fh:
                digest.update(fh.read())
            digest.update(b"\0")

    # Sixteen hex characters carry 64 bits of the digest, which is far past any collision concern
    # for a stamp whose only job is to differ when the packed sources differ. The digest leads and
    # the version trails, because the radio compares a bounded prefix of this line: whatever a long
    # version pushes past that bound then costs nothing, where the other order would have cut the
    # digest instead and made two different trees read as one.
    identity = f"{digest.hexdigest()[:16]}-{version}"
    with open(os.path.join(staging_core, "build.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(identity + "\n")
    return identity


def copy_audio_pack(lang, src_audio, dst_audio):
    src_pack = os.path.join(src_audio, lang, "default")
    if not os.path.isdir(src_pack):
        src_pack = os.path.join(src_audio, lang)
    if not os.path.isdir(src_pack):
        return
    for sub in ["adj", "app", "evt", "stat", "gov"]:
        src_sub = os.path.join(src_pack, sub)
        if os.path.isdir(src_sub):
            dst_sub = os.path.join(dst_audio, sub)
            shutil.copytree(src_sub, dst_sub, dirs_exist_ok=True)


def build_package_for_language(lang, version, output_dir, artifact_name=None):
    temp_dir = tempfile.mkdtemp(prefix="rfsuite_build_")
    try:
        src_root = os.path.join(WORKSPACE_ROOT, "src")
        src_core = os.path.join(src_root, "rfsuite")
        src_widgets = os.path.join(src_root, "widgets")
        src_functions = os.path.join(src_root, "functions")
        src_user = os.path.join(src_root, "rfsuite.user")
        src_audio = os.path.join(src_core, "audio")

        staging_tools = os.path.join(temp_dir, "SCRIPTS", "TOOLS")
        staging_core = os.path.join(staging_tools, "rfsuite-core")
        staging_functions = os.path.join(temp_dir, "SCRIPTS", "FUNCTIONS")
        staging_widgets = os.path.join(temp_dir, "WIDGETS")
        staging_sounds = os.path.join(temp_dir, "SOUNDS", "rf")
        staging_user = os.path.join(staging_tools, "rfsuite.user")

        os.makedirs(staging_core, exist_ok=True)
        os.makedirs(staging_widgets, exist_ok=True)
        os.makedirs(staging_sounds, exist_ok=True)
        os.makedirs(staging_user, exist_ok=True)

        # Copy core files excluding audio and i18n
        for item in os.listdir(src_core):
            if item in ["audio", "i18n"]:
                continue
            s = os.path.join(src_core, item)
            d = os.path.join(staging_core, item)
            if os.path.isdir(s):
                shutil.copytree(s, d, dirs_exist_ok=True)
            else:
                shutil.copy2(s, d)

        # Copy init.lua for i18n
        os.makedirs(os.path.join(staging_core, "i18n"), exist_ok=True)
        shutil.copy2(os.path.join(src_core, "i18n", "init.lua"), os.path.join(staging_core, "i18n", "init.lua"))

        # Copy tool entrypoint
        shutil.copy2(os.path.join(src_root, "main.lua"), os.path.join(staging_tools, "rfsuite.lua"))

        # Copy user default config
        if os.path.isdir(src_user):
            shutil.copytree(src_user, staging_user, dirs_exist_ok=True)

        # Copy widgets. EdgeTX discovers one widget per directory under /WIDGETS, so every
        # directory under src/widgets is staged under its own name rather than one fixed one.
        if os.path.isdir(src_widgets):
            for widget_dir in sorted(os.listdir(src_widgets)):
                s = os.path.join(src_widgets, widget_dir)
                if os.path.isdir(s):
                    shutil.copytree(s, os.path.join(staging_widgets, widget_dir), dirs_exist_ok=True)

        # Copy special-function scripts. EdgeTX offers every lua file directly under
        # /SCRIPTS/FUNCTIONS to a "Play Script" special function, by base name, so the
        # directory is flat and nothing below it is packaged.
        if os.path.isdir(src_functions):
            os.makedirs(staging_functions, exist_ok=True)
            for name in sorted(os.listdir(src_functions)):
                s = os.path.join(src_functions, name)
                if os.path.isfile(s) and name.endswith(".lua"):
                    shutil.copy2(s, os.path.join(staging_functions, name))

        # Copy model templates. EdgeTX lists each directory under /TEMPLATES as a category in
        # its "New model" dialog; a template is the yml the model is created from, a txt shown
        # beside it, and an optional lua the radio fires right after applying the yml.
        src_templates = os.path.join(src_root, "templates")
        if os.path.isdir(src_templates):
            shutil.copytree(src_templates, os.path.join(temp_dir, "TEMPLATES"), dirs_exist_ok=True)

        # Copy sounds
        if os.path.isdir(src_audio):
            copy_audio_pack("en", src_audio, os.path.join(staging_sounds, "en"))
            copy_audio_pack("de", src_audio, os.path.join(staging_sounds, "de"))
            for wav in ["beep.wav", "multibeep.wav", "warn.wav", "alarm.wav"]:
                w_path = os.path.join(src_audio, wav)
                if os.path.isfile(w_path):
                    shutil.copy2(w_path, staging_sounds)

        # Generate theme index
        generate_theme_index(staging_core, staging_user)

        # Precompile and resolve i18n
        py_precompile = os.path.join(WORKSPACE_ROOT, ".vscode", "scripts", "precompile_i18n.py")
        py_resolve = os.path.join(WORKSPACE_ROOT, ".vscode", "scripts", "resolve_i18n_tags.py")
        lang_file = os.path.join(src_core, "i18n", f"{lang}.lua")

        # The templates carry markers too -- their lua and the txt files EdgeTX shows in
        # the template picker -- so each locale's ZIP ships them in its own language.
        staging_templates = os.path.join(temp_dir, "TEMPLATES")

        i18n_roots = [staging_tools, staging_widgets, staging_functions, staging_templates]

        # Every reason this guard can be false is now a refusal rather than a quiet
        # skip. An unknown locale is stopped earlier, in main(); a missing bundle for a
        # known locale, or a missing script, is a broken checkout, and shipping that as
        # a ZIP means the artefact reaches a pilot with no translation done at all.
        missing = [p for p in (py_precompile, py_resolve, lang_file) if not os.path.isfile(p)]
        if missing:
            raise RuntimeError(
                "refusing to package: the i18n stage cannot run, so the ZIP would ship "
                "untranslated. Missing: " + ", ".join(os.path.relpath(p, WORKSPACE_ROOT) for p in missing)
            )

        python_exe = sys.executable if (sys.executable and os.path.isfile(sys.executable)) else (shutil.which("python3") or shutil.which("python") or shutil.which("py") or "python")
        markers_before = count_i18n_markers(i18n_roots)
        subprocess.run([python_exe, py_precompile, "--root", staging_tools], check=True)
        subprocess.run([python_exe, py_precompile, "--root", staging_widgets], check=True)
        subprocess.run([python_exe, py_resolve, "--json", lang_file, "--root", staging_tools], check=True)
        subprocess.run([python_exe, py_resolve, "--json", lang_file, "--root", staging_widgets], check=True)
        if os.path.isdir(staging_functions):
            subprocess.run([python_exe, py_precompile, "--root", staging_functions], check=True)
            subprocess.run([python_exe, py_resolve, "--json", lang_file, "--root", staging_functions], check=True)
        if os.path.isdir(staging_templates):
            subprocess.run([python_exe, py_resolve, "--json", lang_file, "--root", staging_templates], check=True)

        markers_after = count_i18n_markers(i18n_roots)
        print(f"[package] i18n markers: {markers_before} before the stage, {markers_after} after")
        if markers_before > 0 and markers_after >= markers_before:
            raise RuntimeError(
                f"refusing to package: the i18n stage ran but left {markers_after} of "
                f"{markers_before} markers standing, so nothing was translated. "
                "The most likely cause is that every write failed."
            )

        # Record the build identity, after the sources are final and before they are packed
        identity = write_build_identity(temp_dir, staging_core, version)
        print(f"[package] Build identity {identity}")

        # Create output ZIP
        os.makedirs(output_dir, exist_ok=True)
        zip_filename = artifact_name or f"rfsuite-radio-install-v{version}_{lang}.zip"
        zip_path = os.path.join(output_dir, zip_filename)
        if os.path.isfile(zip_path):
            os.remove(zip_path)

        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, _, files in os.walk(temp_dir):
                for f in files:
                    if f.endswith(".luac"):
                        continue
                    full_p = os.path.join(root, f)
                    rel_p = os.path.relpath(full_p, temp_dir)
                    zf.write(full_p, rel_p)

        print(f"[package] Created {zip_path}")
        return zip_path

    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


SELF_TEST_INIT = '''return {
  name = "Example Theme",
  preflight = "preflight.lua",
  inflight = "inflight.lua",
  postflight = "postflight.lua",
  configure = "configure.lua",
  standalone = false,
  pages = {
    { id = "look",  title = "Look",       icon = "icons/look.png" },
    { id = "rows",  title = "Value Rows", icon = "icons/rows.png" },
    { id = "look",  title = "Repeated",   icon = "icons/look.png" },
    { id = "notit" },
    { title = "No Id" },
    { id = "Upper", title = "Rejected" },
    { id = "plain", title = "Plain" },
  },
}
'''

SELF_TEST_NO_PAGES = '''return {
  name = "Example Theme",
  configure = "configure.lua",
  standalone = false,
}
'''


def self_test():
    """Hold the page parser against a theme that declares pages and one that does not.

    No theme in this repository declares `pages`, so a packaging run over the tree exercises
    none of this: it would emit the same index with the parser removed. The block below is what
    says the parser reads a declaration, drops a repeated id, an entry missing a title or an id,
    and an id that is not usable in a menu id -- and the controls are what say it can answer no.
    """
    failures = []

    def check(label, got, want):
        if got == want:
            print(f"[self-test] ok   {label}")
        else:
            print(f"[self-test] FAIL {label}: got {got!r}, wanted {want!r}")
            failures.append(label)

    pages = parse_theme_pages(SELF_TEST_INIT)
    check("three valid entries survive", [p["id"] for p in pages], ["look", "rows", "plain"])
    check("titles are carried", [p["title"] for p in pages], ["Look", "Value Rows", "Plain"])
    check("an icon is optional", [p["icon"] for p in pages],
          ["icons/look.png", "icons/rows.png", None])
    check("a theme without pages declares none", parse_theme_pages(SELF_TEST_NO_PAGES), [])
    check("a truncated list is not a list", parse_theme_pages('return { pages = { { id = "a", title = "A" },'), [])
    check("the index row carries the pages", lua_pages_table(pages),
          ', pages = { { id = "look", title = "Look", icon = "icons/look.png" }, '
          '{ id = "rows", title = "Value Rows", icon = "icons/rows.png" }, '
          '{ id = "plain", title = "Plain" } }')
    check("a theme without pages adds nothing to its row", lua_pages_table([]), "")

    # The controls: the same checks against a parser that answers wrongly have to go red, or a
    # green above says nothing about whether anything was read at all.
    control_ok = parse_theme_pages(SELF_TEST_INIT.replace("pages", "sheets")) == []
    print(f"[self-test] control: a renamed key reads as no pages -- {'red as wanted' if control_ok else 'NOT RED'}")
    if not control_ok:
        failures.append("control: renamed key")

    control_ok = parse_theme_pages(SELF_TEST_NO_PAGES) != parse_theme_pages(SELF_TEST_INIT)
    print(f"[self-test] control: the two blocks differ -- {'red as wanted' if control_ok else 'NOT RED'}")
    if not control_ok:
        failures.append("control: blocks differ")

    if failures:
        print(f"[self-test] {len(failures)} check(s) failed")
        return False
    print("[self-test] all checks passed")
    return True


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--lang", help="Locale to package (e.g. en, de)")
    p.add_argument("--self-test", action="store_true",
                   help="Check the theme page parser against a sample manifest and exit")
    p.add_argument("--artifact-version", default=None, help="Version string baked into the default zip filename (defaults to version.lua)")
    p.add_argument("--artifact-name", default=None, help="Output zip filename (defaults to rfsuite-radio-install-v<version>_<lang>.zip)")
    p.add_argument("--output-dir", default="dist", help="Directory to write the finished zip into (default: dist)")
    return p.parse_args()


def main():
    args = parse_args()
    if args.self_test:
        sys.exit(0 if self_test() else 1)
    if not args.lang:
        print("[package] --lang is required unless --self-test is given")
        sys.exit(2)
    lang = args.lang
    version = args.artifact_version or get_suite_version()
    output_dir = os.path.abspath(args.output_dir)

    available = get_available_languages()
    if lang not in available:
        # A locale that is not a bundle is not a locale. Carrying on used to skip the
        # whole i18n stage and still exit 0, so the ZIP shipped with every marker still
        # standing and nothing said so.
        print(f"[package] REFUSED: '{lang}' is not a locale under src/rfsuite/i18n "
              f"(available: {', '.join(available)}). Refusing rather than shipping an "
              f"artefact with no translation done at all.")
        sys.exit(2)

    print(f"Building RFSuite Radio ZIP package for version v{version}, locale '{lang}'")
    build_package_for_language(lang, version, output_dir, artifact_name=args.artifact_name)


if __name__ == "__main__":
    main()
