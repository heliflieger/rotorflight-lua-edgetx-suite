# i18n/resolve_i18n_tags.py
#!/usr/bin/env python3
"""
Resolve @i18n(...)@ tags into translated strings.

\1

Options:
  --list-transforms        List available transforms and exit

Tag syntax
-----------
@i18n(KEY[, basic_modifier])[:transform(args)...]@

Examples:
  @i18n(app.msg_reload_settings)@
  @i18n(app.msg_reload_settings,upper)@
  @i18n(app.msg_reload_settings):truncate(10)@
  @i18n(app.msg_reload_settings):upperfirst():suffix("!")@

Rules:
- KEY is a dotted path into the JSON translations.
- basic_modifier is optional: "upper" or "lower" (legacy support).
- Any number of transforms may be chained after the closing parenthesis,
  separated by colons. They are applied left → right.
- Arguments to transforms are comma-separated. Strings may be quoted
  with "..." or '...'. Numbers are parsed as int/float. true/false → bool.

Built-in transforms
-------------------
Case:
  upper()       – uppercase
  lower()       – lowercase
  upperfirst()  – first char uppercase, rest lowercase
  capitalize()  – first char uppercase, rest unchanged
  title()       – title case (capitalize each word)
  swapcase()    – invert case

Whitespace:
  trim() / ltrim() / rtrim() – strip whitespace
  collapse_ws()              – collapse multiple spaces/newlines to one space

Length / padding:
  truncate(n[, ellipsis])    – cut to length n, optional ellipsis
  slice(start[, end])        – substring (Python slicing)
  padleft(width[, char])     – left-pad
  padright(width[, char])    – right-pad
  center(width[, char])      – center with padding

Find / replace:
  replace(old,new[,count])   – literal replace
  remove(pattern)            – regex remove
  keep(pattern)              – keep only regex matches
  strip_prefix(pfx)          – remove prefix if present
  strip_suffix(sfx)          – remove suffix if present
  prefix(s) / suffix(s)      – add before/after

Escaping:
  escape_html()              – replace <, >, & with HTML entities
  escape_json()              – escape backslashes and quotes

Notes:
- Unknown transforms are ignored (logged in stats).
- Errors inside a transform do not stop processing; they are recorded.
- After transforms, output is sanitized for safe insertion
  (newlines → "
", double quotes escaped).

CLI examples
------------
  # Preview changes without writing:
  python resolve_i18n_tags.py --json scripts/rfsuite/i18n/en.json --root src --dry-run

  # Apply replacements in-place:
  python resolve_i18n_tags.py --json scripts/rfsuite/i18n/en.json --root src
"""
#!/usr/bin/env python3
import argparse, json, re, sys, os
from pathlib import Path
import shlex
import html
import re as _re

# --- replace your TAG_RE with this (note: IGNORECASE for transforms) ---
TAG_RE = re.compile(
    r'@i18n\(\s*([^)@,]+?)\s*(?:,\s*(upper|lower))?\s*\)'      # @i18n(key[, basic_mod])
    r'((?::[a-z_]+(?:\([^@]*?\))?)*)@',                        # :t1(...):t2 ...
    flags=re.IGNORECASE
)

def _coerce_atom(s: str):
    # try int -> float -> bareword -> string
    try:
        return int(s)
    except ValueError:
        try:
            return float(s)
        except ValueError:
            if s.lower() in ('true', 'false'):
                return s.lower() == 'true'
            return s  # leave as string

def _parse_chain(chain: str):
    """
    chain like ':truncate(10):suffix("…"):replace("x","y",1)'
    -> [('truncate',[10],{}), ('suffix',['…'],{}), ('replace',['x','y',1],{})]
    """
    if not chain:
        return []
    out = []
    # find all segments like :name(args?)
    for seg in filter(None, chain.split(':')):
        m = _re.match(r'([a-z_][a-z0-9_]*)\s*(?:\((.*)\))?$', seg, flags=_re.IGNORECASE)
        if not m:
            continue
        name, argstr = m.group(1).lower(), (m.group(2) or '').strip()
        args = []
        if argstr:
            # shlex handles quotes and commas inside quotes poorly by default;
            # split on commas at top level (no nested parens in our simple grammar).
            parts = []
            current = ''
            depth = 0
            for ch in argstr:
                if ch == '(':
                    depth += 1
                    current += ch
                elif ch == ')':
                    depth = max(0, depth - 1)
                    current += ch
                elif ch == ',' and depth == 0:
                    parts.append(current.strip())
                    current = ''
                else:
                    current += ch
            if current.strip():
                parts.append(current.strip())
            # now strip quotes with shlex (supports "…" or '…')
            for p in parts:
                parsed = shlex.split(p) if p else []
                if len(parsed) == 1:
                    args.append(_coerce_atom(parsed[0]))
                elif len(parsed) == 0:
                    args.append('')
                else:
                    # if someone wrote unescaped spaces not in quotes, join them
                    args.append(_coerce_atom(' '.join(parsed)))
        out.append((name, args, {}))
    return out

def _upperfirst(s: str) -> str:
    return s[:1].upper() + s[1:].lower() if s else s

def _truncate(s: str, n: int, ellipsis: str | None = None) -> str:
    if n < 0: 
        return s
    if len(s) <= n:
        return s
    if ellipsis:
        if n <= len(ellipsis):
            return ellipsis[:n]
        return s[: n - len(ellipsis)] + ellipsis
    return s[:n]

def _collapse_ws(s: str) -> str:
    return _re.sub(r'\s+', ' ', s).strip()

def _slice(s: str, start: int, end: int | None = None) -> str:
    return s[start:end]  # Python slicing semantics

def _ensure_char(c: str) -> str:
    return c[0] if isinstance(c, str) and c else ' '

TRANSFORMS = {
    # case
    'upper': lambda s: s.upper(),
    'lower': lambda s: s.lower(),
    'upperfirst': _upperfirst,
    'capitalize': lambda s: s[:1].upper() + s[1:],
    'title': lambda s: s.title(),
    'swapcase': lambda s: s.swapcase(),

    # trim / spacing
    'trim': lambda s: s.strip(),
    'ltrim': lambda s: s.lstrip(),
    'rtrim': lambda s: s.rstrip(),
    'collapse_ws': _collapse_ws,

    # length / slicing / padding
    'truncate': lambda s, n, ellipsis=None: _truncate(s, int(n), ellipsis),
    'slice': _slice,
    'padleft': lambda s, width, char=' ': s.rjust(int(width), _ensure_char(char)),
    'padright': lambda s, width, char=' ': s.ljust(int(width), _ensure_char(char)),
    'center': lambda s, width, char=' ': s.center(int(width), _ensure_char(char)),

    # find / replace
    'replace': lambda s, old, new, count=None: s.replace(str(old), str(new), int(count) if count is not None else -1),
    'remove': lambda s, pattern: _re.sub(str(pattern), '', s),
    'keep': lambda s, pattern: ' '.join(_re.findall(str(pattern), s)),
    'strip_prefix': lambda s, p: s[len(p):] if s.startswith(str(p)) else s,
    'strip_suffix': lambda s, p: s[:-len(p)] if len(p) and s.endswith(str(p)) else s,
    'prefix': lambda s, p: str(p) + s,
    'suffix': lambda s, p: s + str(p),

    # escaping
    'escape_html': lambda s: html.escape(s, quote=True),
    'escape_json': lambda s: s.replace('\\', '\\\\').replace('"', r'\"'),
}

TRANSFORM_HELP = {
    # case
    'upper':        'upper() – uppercase',
    'lower':        'lower() – lowercase',
    'upperfirst':   'upperfirst() – first char uppercase, rest lowercase',
    'capitalize':   'capitalize() – first char uppercase, rest unchanged',
    'title':        'title() – title case (capitalize each word)',
    'swapcase':     'swapcase() – invert case',

    # whitespace
    'trim':         'trim() – strip leading/trailing whitespace',
    'ltrim':        'ltrim() – strip leading whitespace',
    'rtrim':        'rtrim() – strip trailing whitespace',
    'collapse_ws':  'collapse_ws() – collapse multiple spaces/newlines to one space',

    # length / padding
    'truncate':     'truncate(n[, ellipsis]) – cut to length n, optional ellipsis',
    'slice':        'slice(start[, end]) – substring (Python slicing)',
    'padleft':      'padleft(width[, char]) – left-pad',
    'padright':     'padright(width[, char]) – right-pad',
    'center':       'center(width[, char]) – center with padding',

    # find / replace
    'replace':      'replace(old,new[,count]) – literal replace',
    'remove':       'remove(pattern) – regex remove',
    'keep':         'keep(pattern) – keep only regex matches',
    'strip_prefix': 'strip_prefix(pfx) – remove prefix if present',
    'strip_suffix': 'strip_suffix(sfx) – remove suffix if present',
    'prefix':       'prefix(s) – add before',
    'suffix':       'suffix(s) – add after',

    # escaping
    'escape_html':  'escape_html() – replace <, >, & with HTML entities',
    'escape_json':  'escape_json() – escape backslashes and quotes',
}
def print_transform_list():
    keys = sorted(TRANSFORM_HELP.keys())
    print("[i18n] Available transforms:")
    for k in keys:
        print("  - " + TRANSFORM_HELP[k])

def apply_transform_pipeline(s: str, basic_mod: str | None, chain: str, stats: dict) -> str:
    # basic_mod from @i18n(key, upper|lower)
    if basic_mod:
        fn = TRANSFORMS.get(basic_mod.lower())
        if fn:
            s = fn(s)

    for name, args, _ in _parse_chain(chain):
        fn = TRANSFORMS.get(name)
        if not fn:
            stats.setdefault('unknown_transform', {}).setdefault(name, 0)
            stats['unknown_transform'][name] += 1
            continue
        try:
            s = fn(s, *args)
        except Exception as e:
            stats.setdefault('transform_errors', []).append(f"{name}({args}) -> {e}")
    return s


def load_translations(path: Path) -> dict:
    if path.suffix.lower() == '.lua':
        with path.open('r', encoding='utf-8') as f:
            lines = f.readlines()
            
        json_str = ""
        for line in lines:
            line = re.sub(r'--.*$', '', line)
            stripped = line.strip()
            if not stripped:
                continue
                
            if stripped == "return {":
                json_str += "{\n"
                continue
                
            m = re.match(r'^(?:\[\s*["\']([a-zA-Z0-9_]+)["\']\s*\]|([a-zA-Z0-9_]+))\s*=\s*\{\s*$', stripped)
            if m:
                key = m.group(1) or m.group(2)
                json_str += f'"{key}": {{\n'
                continue
                
            m = re.match(r'^(?:\[\s*["\']([a-zA-Z0-9_]+)["\']\s*\]|([a-zA-Z0-9_]+))\s*=\s*(.*?),?$', stripped)
            if m:
                key = m.group(1) or m.group(2)
                val = m.group(3).strip()
                
                # If val is a table on a single line, e.g. { name = "Flight Tuning" }
                if val.startswith('{') and val.endswith('}'):
                    val_content = val[1:-1].strip()
                    int_m = re.match(r'^(?:\[\s*["\']([a-zA-Z0-9_]+)["\']\s*\]|([a-zA-Z0-9_]+))\s*=\s*["\'](.*?)["\']$', val_content)
                    if int_m:
                        int_key = int_m.group(1) or int_m.group(2)
                        val = f'{{"{int_key}": "{int_m.group(3)}"}}'
                # If val is a string literal, decode its escapes and dump as valid JSON string
                elif (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                    inner = val[1:-1]
                    raw_bytes = inner.encode('utf-8', errors='replace')
                    try:
                        import codecs
                        decoded_bytes, _ = codecs.escape_decode(raw_bytes)
                        val_str = decoded_bytes.decode('utf-8', errors='replace')
                    except Exception:
                        val_str = inner
                    val = json.dumps(val_str, ensure_ascii=False)
                    
                json_str += f'"{key}": {val},\n'
                continue
                
            if stripped == "}" or stripped == "}," or stripped == "};":
                json_str += "},\n"
                continue
                
            json_str += line

        json_str = re.sub(r',\s*([\]}])', r'\1', json_str)
        json_str = re.sub(r',\s*$', '', json_str)
        
        try:
            return json.loads(json_str)
        except Exception as e:
            print(f"Failed to parse Lua translation table {path} as JSON: {e}")
            raise
            
    with path.open('r', encoding='utf-8') as f:
        return json.load(f)



def resolve_key(tree: dict, dotted: str):
    """
    Walk dotted path. If the leaf is a dict like
    { english: "...", translation: "...", reverse_text: true/false },
    prefer 'translation', fall back to 'english'. Otherwise cast to str.
    """
    node = tree
    for part in dotted.split('.'):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]

    # Leaf handling
    if isinstance(node, dict):
        reverse_flag = node.get('reverse_text') if isinstance(node.get('reverse_text'), bool) else None
        # common schema: english/translation/needs_translation
        if 'translation' in node and isinstance(node['translation'], (str, int, float)):
            return str(node['translation']), reverse_flag
        if 'english' in node and isinstance(node['english'], (str, int, float)):
            return str(node['english']), reverse_flag
        # if dict but not the expected shape, refuse
        return None

    if node is None:
        return None

    # Primitive leaf
    return str(node), None

def apply_modifier(s: str, mod: str | None):
    if not mod:
        return s
    if mod == 'upper':
        return s.upper()
    if mod == 'lower':
        return s.lower()
    return s  # unknown modifier, ignore

def _sanitize_for_insertion(s: str) -> str:
    """
    Ensure:
      - any CRLF/CR become LF,
      - literal backslash-n sequences are written for line breaks,
      - double quotes are escaped.
    """
    # Normalize all newlines to LF
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    # Turn actual LF characters into the two-character sequence \n
    s = s.replace("\n", r"\n")
    # Escape double quotes
    s = s.replace('"', r'\"')
    return s

def _reverse_text_for_hebrew_display(s: str) -> str:
    # Reverse each logical line to compensate for environments that render RTL text backwards.
    normalized = s.replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(line[::-1] for line in normalized.split("\n"))

def _contains_hebrew_chars(s: str) -> bool:
    return _re.search(r'[\u0590-\u05FF]', s) is not None

def _should_reverse_text(text: str, reverse_flag: bool | None) -> bool:
    if reverse_flag is True:
        return True
    if reverse_flag is False:
        return False
    return _contains_hebrew_chars(text)


def get_esc_fallback(key: str) -> str:
    # key structure: app.modules.esc_tools.mfg.<mfg>.<param>
    parts = key.split('.')
    if len(parts) < 6:
        return None
    param = parts[5]
    
    # Common dictionary lookup for no-underscore keys (mostly blheli_s / bluejay)
    lookup = {
        "beacondelay": "Beacon Delay",
        "beaconstrength": "Beacon Strength",
        "beepstrength": "Beep Strength",
        "brakeonstop": "Brake On Stop",
        "demagcompensation": "Demag Compensation",
        "motordirection": "Motor Direction",
        "motortiming": "Motor Timing",
        "temperatureprotection": "Temperature Protection",
        "ppmcenterthrottle": "PPM Center Throttle",
        "ppmmaxthrottle": "PPM Max Throttle",
        "ppmminthrottle": "PPM Min Throttle",
        "startuppower": "Startup Power",
        "waitingforesc": "Waiting for ESC...",
        "brakingmode": "Braking Mode",
        "brakingstrength": "Braking Strength",
        "dithering": "Dithering",
        "forceedtarm": "Force DShot Arm",
        "ledcontrol": "LED Control",
        "lowrpmpowerprotection": "Low RPM Power Protection",
        "maxstartuppower": "Max Startup Power",
        "minstartuppower": "Min Startup Power",
        "powerrating": "Power Rating",
        "pwmfrequency": "PWM Frequency",
        "rampuppower": "Rampup Power",
        "rampupstartpower": "Rampup Start Power",
        "startupbeep": "Startup Beep",
        "threshold48to24": "Threshold 48 to 24",
        "threshold96to48": "Threshold 96 to 48",
        "extra_msg_save": "Save successful"
    }
    
    if param in lookup:
        return lookup[param]
        
    # If it has underscores, split and capitalize
    if '_' in param:
        return ' '.join(word.capitalize() for word in param.split('_'))
        
    # Otherwise just capitalize the first letter
    return param.capitalize()


def replace_tags_in_text(text: str, translations: dict, stats: dict, fallback_translations: dict = None):
    def _sub(m: re.Match):
        key = m.group(1).strip()
        basic_mod = m.group(2)  # upper|lower
        chain = m.group(3) or ''  # like ':truncate(10):suffix("…")'

        # Parse inline fallback if present
        inline_fallback = None
        if '|' in key:
            key, inline_fallback = key.split('|', 1)
            # Decode the inline fallback
            inline_fallback = (inline_fallback
                               .replace('__PIPE__', '|')
                               .replace('__RPAREN__', ')')
                               .replace('__LPAREN__', '(')
                               .replace('__COMMA__', ',')
                               .replace('__AT__', '@'))

        ALIASES = {
            "app.pages.setup_controls.": "app.modules.controls.",
            "app.modules.esc_tools.name": "app.modules.esc_motors.esc_tools",
            "widgets.governor.THR-OFF": "widgets.governor.THROFF",
        }
        for old, new in ALIASES.items():
            if key.startswith(old):
                key = new + key[len(old):]
                break

        ESC_FALLBACKS = {
            "app.modules.esc_tools.mfg.blheli_s.name": "BLHeli_S",
            "app.modules.esc_tools.mfg.bluejay.name": "Bluejay",
            "app.modules.esc_tools.mfg.flrtr.name": "Flyrotor",
            "app.modules.esc_tools.mfg.hw5.name": "Hobbywing",
            "app.modules.esc_tools.mfg.omp.name": "OMP",
            "app.modules.esc_tools.mfg.scorp.name": "Scorpion",
            "app.modules.esc_tools.mfg.xdfly.name": "XDFly",
            "app.modules.esc_tools.mfg.yge.name": "YGE",
            "app.modules.esc_tools.mfg.ztw.name": "ZTW",
            "app.modules.esc_tools.mfg.blheli_s.waitingforesc": "Waiting for ESC...",
            "app.modules.esc_tools.mfg.bluejay.waitingforesc": "Waiting for ESC...",
            "app.modules.esc_tools.mfg.blheli_s.basic": "Basic",
            "app.modules.esc_tools.mfg.blheli_s.advanced": "Advanced",
            "app.modules.esc_tools.mfg.blheli_s.input": "Input",
            "app.modules.esc_tools.mfg.bluejay.beacon": "Beacon",
            "app.modules.esc_tools.mfg.bluejay.brake": "Brake",
            "app.modules.esc_tools.mfg.bluejay.general": "General",
            "app.modules.esc_tools.mfg.bluejay.other": "Other",
            "app.modules.esc_tools.mfg.flrtr.advanced": "Advanced",
            "app.modules.esc_tools.mfg.flrtr.basic": "Basic",
            "app.modules.esc_tools.mfg.flrtr.governor": "Governor",
            "app.modules.esc_tools.mfg.flrtr.other": "Other",
            "app.modules.esc_tools.mfg.hw5.advanced": "Advanced",
            "app.modules.esc_tools.mfg.hw5.basic": "Basic",
            "app.modules.esc_tools.mfg.hw5.rotation": "Rotation",
            "app.modules.esc_tools.mfg.omp.advanced": "Advanced",
            "app.modules.esc_tools.mfg.omp.basic": "Basic",
            "app.modules.esc_tools.mfg.omp.governor": "Governor",
            "app.modules.esc_tools.mfg.scorp.advanced": "Advanced",
            "app.modules.esc_tools.mfg.scorp.basic": "Basic",
            "app.modules.esc_tools.mfg.scorp.limits": "Limits",
            "app.modules.esc_tools.mfg.xdfly.advanced": "Advanced",
            "app.modules.esc_tools.mfg.xdfly.basic": "Basic",
            "app.modules.esc_tools.mfg.xdfly.governor": "Governor",
            "app.modules.esc_tools.mfg.yge.advanced": "Advanced",
            "app.modules.esc_tools.mfg.yge.basic": "Basic",
            "app.modules.esc_tools.mfg.yge.other": "Other",
            "app.modules.esc_tools.mfg.ztw.advanced": "Advanced",
            "app.modules.esc_tools.mfg.ztw.basic": "Basic",
            "app.modules.esc_tools.mfg.ztw.governor": "Governor",
            "api.ESC_PARAMETERS_HW5.tbl_disabled": "Disabled",
            "api.ESC_PARAMETERS_HW5.tbl_autocalculate": "Auto-Calculate",
            "api.ESC_PARAMETERS_HW5.tbl_normal": "Normal",
            "api.ESC_PARAMETERS_HW5.tbl_reverse": "Reverse",
            "api.ESC_PARAMETERS_HW5.tbl_cw": "CW",
            "api.ESC_PARAMETERS_HW5.tbl_ccw": "CCW",
            "api.ESC_PARAMETERS_HW5.tbl_proportional": "Proportional",
        }

        resolved = resolve_key(translations, key)
        if resolved is None and fallback_translations is not None:
            resolved = resolve_key(fallback_translations, key)

        if resolved is None:
            esc_fb = get_esc_fallback(key)
            if esc_fb is not None:
                resolved_text, reverse_flag = esc_fb, False
            elif key in ESC_FALLBACKS:
                resolved_text, reverse_flag = ESC_FALLBACKS[key], False
            elif inline_fallback is not None:
                resolved_text, reverse_flag = inline_fallback, False
            else:
                stats.setdefault('unresolved', {}).setdefault(key, 0)
                stats['unresolved'][key] += 1
                return m.group(0)  # leave tag untouched
        else:
            resolved_text, reverse_flag = resolved

        # apply pipeline then sanitize for insertion into code
        resolved_text = apply_transform_pipeline(str(resolved_text), basic_mod, chain, stats)
        if _should_reverse_text(resolved_text, reverse_flag):
            resolved_text = _reverse_text_for_hebrew_display(resolved_text)
        resolved_text = _sanitize_for_insertion(resolved_text)
        return resolved_text

    new_text, n = TAG_RE.subn(_sub, text)
    return new_text, n


def process_file(path: Path, translations: dict, fallback_translations: dict = None, dry_run=False, lang='en'):
    """Resolve one file.

    Returns (replaced, unresolved, write_failures).

    write_failures is separate from replaced on purpose. A file that could not be
    written used to report 0 replacements, which is the same number a file that
    needed no change reports, so a run in which every write failed was
    indistinguishable from a clean tree.
    """
    before = path.read_text(encoding='utf-8')
    stats = {}
    new_text, n = replace_tags_in_text(before, translations, stats, fallback_translations)

    if "@i18n_language@" in new_text:
        new_text = new_text.replace("@i18n_language@", lang)
        n += 1

    if n == 0:
        return 0, stats.get('unresolved', {}), 0

    if dry_run:
        print(f"[i18n] DRY-RUN would update {path} — {n} replacement(s)")
        return n, stats.get('unresolved', {}), 0

    # Nothing to write is not a failed write. TAG_RE.subn counts every match,
    # including one whose key resolves to nothing and is therefore handed back
    # untouched, so `n > 0` does not mean the text was meant to change. Without
    # this a file whose only marker is unresolved is rewritten with its own
    # content, the verification below reads the unchanged file as a write that
    # did not take, and the run reports a *disk* failure for what is a missing
    # key. The unresolved key is counted in stats['unresolved'] either way, and
    # that is what decides the exit status.
    if new_text == before:
        return 0, stats.get('unresolved', {}), 0

    # check writability (best-effort on Windows)
    writable = os.access(path, os.W_OK) and os.access(path.parent, os.W_OK)
    if not writable:
        print(f"[i18n] NOTE: {path} looks protected (Program Files?) — you may need to run elevated or deploy to a staging folder first.")

    # attempt write with good diagnostics
    try:
        path.write_text(new_text, encoding='utf-8')
    except PermissionError as e:
        print(f"[i18n] FAILED to write (permission): {path} — {e}")
        return 0, stats.get('unresolved', {}), 1
    except OSError as e:
        print(f"[i18n] FAILED to write (os error): {path} — {e}")
        return 0, stats.get('unresolved', {}), 1

    # verify the write actually stuck
    try:
        after = path.read_text(encoding='utf-8')
    except Exception as e:
        print(f"[i18n] WARNING: couldn’t read back for verify: {path} — {e}")
        after = None

    # The text was meant to change (checked above) and the file still reads back
    # as it was, or cannot be read at all: a write that did not take effect.
    if after is None or after == before:
        print(f"[i18n] WARNING: write verification shows no change: {path}")
        return 0, stats.get('unresolved', {}), 1

    return n, stats.get('unresolved', {}), 0

def iter_source_files(root: Path, exts=('.lua', '.ts', '.tsx', '.js', '.jsx', '.json', '.md', '.txt')):
    for p in root.rglob('*'):
        if p.is_file() and p.suffix.lower() in exts:
            yield p

def self_test():
    """Prove the exit status can go red, and stays green on a clean tree.

    A gate nobody has watched go red is not known to be a gate. The packager runs
    this resolver with check=True, so a resolver that cannot report a failure is
    exactly the failure this exit status exists to prevent.

    Returns 0 if every case behaved as specified, 1 otherwise.
    """
    import stat
    import tempfile

    bundle = (
        "return {\n"
        "  selftest = {\n"
        '    known = "Known Text",\n'
        "  },\n"
        "}\n"
    )

    # (label, marker key, file made read-only, expected status, file must have
    # changed, expected write failures reported)
    #
    # The write-failure column is the point of the third one. An unresolved key
    # used to be reported as a failed write as well, because the untouched marker
    # was counted as a replacement, the file was rewritten with its own content,
    # and the write verification read the unchanged file as a write that did not
    # take. The exit status was right in both cases and the reason was not, which
    # points a reader at the disk when the key is what is missing.
    cases = [
        ("clean tree, key resolves", "known", False, 0, True, 0),
        ("unresolved key", "absent", False, 1, False, 0),
        ("file that cannot be written", "known", True, 1, False, 1),
    ]

    import io
    from contextlib import redirect_stdout

    ok = True
    for label, key, readonly, expect, expect_changed, expect_wf in cases:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "i18n").mkdir()
            bundle_path = base / "i18n" / "en.lua"
            bundle_path.write_text(bundle, encoding='utf-8')
            root = base / "src"
            root.mkdir()
            target = root / "page.lua"
            original = 'title = "@i18n(selftest.%s)@",\n' % key
            target.write_text(original, encoding='utf-8')

            # Captured before the chmod, because restoring "writable" is not the
            # same as restoring what was there. stat.S_IWRITE is 0o200 on POSIX, so
            # chmod-ing to it leaves the file --w------- with every read bit
            # cleared, and the read-back below then raises PermissionError. Windows
            # only toggles the read-only attribute for the same call, which is why
            # this passed on a Windows workstation and failed on the
            # ubuntu-latest job in checks.yml -- the first run of this step on any
            # push, since pr.yml does not run it.
            saved_mode = os.stat(target).st_mode

            if readonly:
                # Windows honours the read-only attribute with a real PermissionError
                # on write, which is the path a protected install takes.
                os.chmod(target, stat.S_IREAD)

            print(f"\n=== self-test: {label} ===")
            saved_argv = sys.argv
            sys.argv = [saved_argv[0], "--json", str(bundle_path), "--root", str(root)]
            buf = io.StringIO()
            try:
                with redirect_stdout(buf):
                    status = main() or 0
            finally:
                sys.argv = saved_argv
                if readonly:
                    os.chmod(target, saved_mode)
            output = buf.getvalue()
            print(output, end="")

            problems = []
            got_wf = None
            m_wf = re.search(r"write failures: (\d+)", output)
            if m_wf:
                got_wf = int(m_wf.group(1))
            if got_wf != expect_wf:
                # Named on its own, because a case that is only "not 0" would
                # pass on a run that reported nothing at all.
                problems.append(
                    "reported %s write failure(s), expected %d" % (got_wf, expect_wf))
            if not os.access(target, os.R_OK) or not os.access(target, os.W_OK):
                # The restore did not put the file back the way it was: the read bit,
                # the write bit or both are gone. Report it as a failure of this case
                # instead of letting the read-back raise, which would abort the
                # remaining cases and hide the exit-status verdicts.
                problems.append(
                    "file is not usable after the restore (readable=%s, writable=%s)"
                    % (os.access(target, os.R_OK), os.access(target, os.W_OK)))
                changed = False
            else:
                changed = target.read_text(encoding='utf-8') != original
            if status != expect:
                problems.append(f"exit status {status}, expected {expect}")
            if changed != expect_changed:
                problems.append(f"file changed={changed}, expected {expect_changed}")

            if problems:
                ok = False
                print(f"[self-test] FAIL: {label}: " + "; ".join(problems))
            else:
                print(f"[self-test] PASS: {label} (exit {status}, file changed={changed})")

    print()
    if ok:
        print("[self-test] all cases behaved as specified")
        return 0
    print("[self-test] FAILED: the exit status does not tell the truth")
    return 1


def main():
    ap = argparse.ArgumentParser(description="Resolve @i18n(...)@ tags in a codebase")
    ap.add_argument('--list-transforms', action='store_true', help='List available transforms and exit')
    ap.add_argument('--self-test', action='store_true',
                    help='Prove the exit status reports unresolved keys and failed writes')
    ap.add_argument('--json', required=False, help='Path to en.json')
    ap.add_argument('--root', required=False, help='Root of codebase to scan')
    ap.add_argument('--dry-run', action='store_true', help='Do not write changes')
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    # Before the --json/--root check, not after: the message on that check says
    # both are required "unless --list-transforms ... is given", and with the
    # order the other way round that sentence was false -- the flag was refused
    # for wanting exactly what it was asked to do without. (This is how master
    # behaved too, so it was never a regression here; it was just a message that
    # lied about its own script.)
    if args.list_transforms:
        print_transform_list()
        return 0

    if not args.json or not args.root:
        ap.error('--json and --root are required unless --list-transforms or --self-test is given')

    translations_path = Path(args.json)
    translations = load_translations(translations_path)
    
    # Try to load en.lua or en.json as fallback if we are not already processing english
    fallback_translations = None
    if translations_path.stem != "en":
        fallback_path = translations_path.parent / f"en{translations_path.suffix}"
        if fallback_path.exists():
            try:
                fallback_translations = load_translations(fallback_path)
                print(f"[i18n] Loaded English fallback from {fallback_path}")
            except Exception as e:
                print(f"[i18n] WARNING: could not load English fallback: {e}")

    root = Path(args.root)
    total_files_changed = 0
    total_replacements = 0
    unresolved_agg = {}
    write_failures = 0

    for f in iter_source_files(root):
        replaced, unresolved, failed = process_file(f, translations, fallback_translations=fallback_translations, dry_run=args.dry_run, lang=translations_path.stem.lower())
        write_failures += failed
        if replaced:
            total_files_changed += 1
            total_replacements += replaced
        # aggregate unresolved
        for k, c in unresolved.items():
            unresolved_agg[k] = unresolved_agg.get(k, 0) + c

    print(f"[i18n] DONE — files changed: {total_files_changed}, total replacements: {total_replacements}, write failures: {write_failures}")

    if unresolved_agg:
        print("[i18n] unresolved keys:")
        # show top offenders first
        for k, c in sorted(unresolved_agg.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"  {k}: {c} occurrence(s)")

    # main() returns None on every path, so sys.exit(main()) used to exit 0
    # whatever happened. An unresolved key means a marker reaches the radio as
    # itself, and a failed write means the file still holds one; both are red.
    if unresolved_agg:
        print(f"[i18n] FAILED: {len(unresolved_agg)} unresolved key(s). The tree still carries markers that no bundle can resolve.")
        return 1

    if write_failures:
        print(f"[i18n] FAILED: {write_failures} file(s) that needed a change could not be written.")
        return 1

    return 0
if __name__ == "__main__":
    sys.exit(main())
