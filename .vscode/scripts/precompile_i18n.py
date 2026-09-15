import os
import re
import sys
from pathlib import Path

def process_file(file_path):
    try:
        with open(file_path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
    except Exception as e:
        print(f"[PRECOMPILE] Error reading {file_path}: {e}")
        return
        
    changed = False

    def encode_fallback(s):
        return s.replace('|', '__PIPE__').replace(')', '__RPAREN__').replace('(', '__LPAREN__').replace(',', '__COMMA__').replace('@', '__AT__')
    
    # 1. Find pageT / Common.pageT prefix
    m_prefix = re.search(r'(?:pageT|Common\.pageT)\s*\(\s*["\']([^"\']+)["\']\s*\)', content)
    prefix = m_prefix.group(1) if m_prefix else None
    
    # 2. If it's a help file, let's also look for keyPrefix
    if not prefix:
        m_keyprefix = re.search(r'keyPrefix\s*=\s*["\']([^"\']+)["\']', content)
        if m_keyprefix:
            prefix = m_keyprefix.group(1)
            # Remove the "app.pages." from keyPrefix if it's there
            if prefix.startswith("app.pages."):
                prefix = prefix[10:]

    # 2b. A page built by Common.buildSimplePage names its own key as the second argument,
    # so it needs neither a pageT call nor a keyPrefix local to be resolvable. Without this
    # such a page produces no marker at all and ships its English fallbacks in every locale.
    if not prefix:
        m_simple = re.search(r'buildSimplePage\s*\(\s*[^,]+,\s*["\']([^"\']+)["\']', content)
        if m_simple:
            prefix = m_simple.group(1)
                
    if prefix:
        full_prefix = f"app.pages.{prefix}"
        
        # The cross-page form -- Common.t with a page key of its own, with or without a
        # fallback -- names the page whose block it borrows a key from. It is substituted
        # BEFORE the generic pageText/t pattern below, because both can match the same
        # call and only this one resolves the borrowed page key.
        def sub_commont(m):
            page_key = m.group(1)
            key = m.group(2)
            if m.group(4) is not None:
                fallback = encode_fallback(m.group(4))
                return f'"@i18n(app.pages.{page_key}.{key}|{fallback})@"'
            return f'"@i18n(app.pages.{page_key}.{key})@"'
        pattern_common = r'\bCommon\.t\s*\(\s*(?:(?:[a-zA-Z0-9_.]+\.)?i18n|nil)\s*,\s*["\']([^"\']+)["\']\s*,\s*["\']([^"\']+)["\'](?:\s*,\s*(["\'])(.*?)\3)?\s*\)'
        new_content, count = re.subn(pattern_common, sub_commont, content)
        if count > 0:
            content = new_content
            changed = True

        # Replace pageText(i18n, "key", "fallback") or pageText(ctx.i18n, "key", "fallback") or t(i18n, "key", "fallback") or t(ctx.i18n, "key")
        pattern = r'(?<![\w.])(?:pageText|t)\s*\(\s*(?:(?:[a-zA-Z0-9_.]+\.)?i18n|nil)\s*,\s*["\']([^"\']+)["\'](?:\s*,\s*(["\'])(.*?)\2)?\s*\)'
        def sub_pagetext(m):
            key = m.group(1)
            if m.group(3) is not None:
                fallback = encode_fallback(m.group(3))
                return f'"@i18n({full_prefix}.{key}|{fallback})@"'
            return f'"@i18n({full_prefix}.{key})@"'
        new_content, count = re.subn(pattern, sub_pagetext, content)
        if count > 0:
            content = new_content
            changed = True
            
        # Support titleKey = "key", titleFallback = "fallback"
        pattern_title = r'\btitleKey\s*=\s*["\']([^"\']+)["\']\s*,\s*titleFallback\s*=\s*(["\'])(.*?)\2'
        def sub_title(m):
            key = m.group(1)
            fallback = encode_fallback(m.group(3))
            return f'titleKey = "{key}", titleFallback = "@i18n({full_prefix}.{key}|{fallback})@"'
        new_content, count = re.subn(pattern_title, sub_title, content)
        if count > 0:
            content = new_content
            changed = True

        # Support labelKey = "key", labelFallback = "fallback" or fallback = "fallback"
        pattern_label = r'\blabelKey\s*=\s*["\']([^"\']+)["\']\s*,\s*(labelFallback|fallback)\s*=\s*(["\'])(.*?)\3'
        def sub_label(m):
            key = m.group(1)
            prop = m.group(2)
            fallback = encode_fallback(m.group(4))
            return f'labelKey = "{key}", {prop} = "@i18n({full_prefix}.{key}|{fallback})@"'
        new_content, count = re.subn(pattern_label, sub_label, content)
        if count > 0:
            content = new_content
            changed = True

        # Support valueKey = "key", valueFallback = "fallback" -- the other half of the
        # row that labelKey/labelFallback above covers. A settings row carries both, and
        # resolving only the label leaves every value in English.
        pattern_value = r'\bvalueKey\s*=\s*["\']([^"\']+)["\']\s*,\s*(valueFallback|fallback)\s*=\s*(["\'])(.*?)\3'
        def sub_value(m):
            key = m.group(1)
            prop = m.group(2)
            fallback = encode_fallback(m.group(4))
            return f'valueKey = "{key}", {prop} = "@i18n({full_prefix}.{key}|{fallback})@"'
        new_content, count = re.subn(pattern_value, sub_value, content)
        if count > 0:
            content = new_content
            changed = True

        # 3. If it's a help file with fallback = { ... }
        m_fallback = re.search(r'fallback\s*=\s*\{(.*?)\}', content, re.DOTALL)
        if m_fallback:
            fallback_block = m_fallback.group(1)
            strings = re.findall(r'(["\'])(.*?)\1', fallback_block)
            new_block = fallback_block
            for idx, (quote, string) in enumerate(strings):
                fallback = encode_fallback(string)
                tag = f'"@i18n({full_prefix}.help_p{idx+1}|{fallback})@"'
                new_block = new_block.replace(f'{quote}{string}{quote}', tag, 1)
            content = content.replace(fallback_block, new_block, 1)
            changed = True

    # 3b. The section header of a simple settings page. It is passed POSITIONALLY --
    # buildSimplePage(ctx, "pageKey", "sectionKey", "Fallback", rows) -- so none of the
    # key = value patterns above can see it, and it stayed English in every locale.
    pattern_section = (r'(\bbuildSimplePage\s*\(\s*[^,]+,\s*)(["\'])([^"\']+)\2(\s*,\s*)'
                       r'(["\'])([^"\']+)\5(\s*,\s*)(["\'])(.*?)\8')
    def sub_section(m):
        page_key, section_key = m.group(3), m.group(6)
        fallback = encode_fallback(m.group(9))
        return (f'{m.group(1)}"{page_key}"{m.group(4)}"{section_key}"{m.group(7)}'
                f'"@i18n(app.pages.{page_key}.{section_key}|{fallback})@"')
    new_content, count = re.subn(pattern_section, sub_section, content)
    if count > 0:
        content = new_content
        changed = True

    # 4. Header buttons in header.lua
    if file_path.name == "header.lua":
        pattern_header = r'\bt\s*\(\s*["\']([^"\']+)["\']\s*,\s*(["\'])(.*?)\2\s*\)'
        def sub_header(m):
            key = m.group(1)
            fallback = encode_fallback(m.group(3))
            return f'"@i18n(app.actions.{key}|{fallback})@"'
        new_content, count = re.subn(pattern_header, sub_header, content)
        if count > 0:
            content = new_content
            changed = True

    # 5. Widget dynamic translation in runtime.lua & fullscreen_menu.lua
    # Pattern: (t and t("widgets.dashboard.key")) or "fallback"
    pattern_widget_t_and_t = r'\(?\s*\(?\s*\bt\s+and\s+t\s*\(\s*["\']([^"\']+)["\']\s*\)\s*\)?\s*\)?\s*or\s*(["\'])(.*?)\2'
    def sub_widget_t_and_t(m):
        key = m.group(1)
        fallback = encode_fallback(m.group(3))
        return f'"@i18n({key}|{fallback})@"'
    new_content, count = re.subn(pattern_widget_t_and_t, sub_widget_t_and_t, content)
    if count > 0:
        content = new_content
        changed = True

    # Pattern: t("widgets.dashboard.key", "fallback")
    pattern_widget_t = r'\bt\s*\(\s*["\'](widgets\.dashboard\.[^"\']+)["\']\s*,\s*(["\'])(.*?)\2\s*\)'
    def sub_widget_t(m):
        key = m.group(1)
        fallback = encode_fallback(m.group(3))
        return f'"@i18n({key}|{fallback})@"'
    new_content, count = re.subn(pattern_widget_t, sub_widget_t, content)
    if count > 0:
        content = new_content
        changed = True

    # Pattern: state.i18n and state.i18n.t and state.i18n.t("key") or "fallback"
    pattern_i18n_full = r'\b(?:[a-zA-Z0-9_]+\.)?i18n\s+and\s+(?:[a-zA-Z0-9_]+\.)?i18n\.t\s+and\s+(?:[a-zA-Z0-9_]+\.)?i18n\.t\s*\(\s*["\']([^"\']+)["\']\s*\)\s*or\s*(["\'])(.*?)\2'
    def sub_i18n_full(m):
        key = m.group(1)
        fallback = encode_fallback(m.group(3))
        return f'"@i18n({key}|{fallback})@"'
    new_content, count = re.subn(pattern_i18n_full, sub_i18n_full, content)
    if count > 0:
        content = new_content
        changed = True

    # Pattern: tr and tr("key") or "fallback"
    pattern_tr_or = r'\btr\s+and\s+tr\s*\(\s*["\']([^"\']+)["\']\s*\)\s*or\s*(["\'])(.*?)\2'
    def sub_tr_or(m):
        key = m.group(1)
        fallback = encode_fallback(m.group(3))
        return f'"@i18n({key}|{fallback})@"'
    new_content, count = re.subn(pattern_tr_or, sub_tr_or, content)
    if count > 0:
        content = new_content
        changed = True

    # Pattern: tr("key", "fallback")
    pattern_tr_call = r'\btr\s*\(\s*["\']([a-zA-Z0-9_]+\.[a-zA-Z0-9_\.]+)["\']\s*,\s*(["\'])(.*?)\2\s*\)'
    def sub_tr_call(m):
        key = m.group(1)
        fallback = encode_fallback(m.group(3))
        return f'"@i18n({key}|{fallback})@"'
    new_content, count = re.subn(pattern_tr_call, sub_tr_call, content)
    if count > 0:
        content = new_content
        changed = True

    # Pattern: i18n.t("key")
    pattern_i18n_t = r'\b(?:[a-zA-Z0-9_]+\.)?i18n\.t\s*\(\s*["\']([^"\']+)["\']\s*\)'
    new_content, count = re.subn(pattern_i18n_t, lambda m: f'"@i18n({m.group(1)})@"', content)
    if count > 0:
        content = new_content
        changed = True

    # 6. Specific splash screen defaults in runtime.lua and splash.lua
    if file_path.name == "splash.lua":
        new_content, count = re.subn(r'["\']Please wait for telemetry["\']', r'"@i18n(widgets.dashboard.please_wait_for_telemetry)@"', content)
        if count > 0:
            content = new_content
            changed = True
            
    if file_path.name == "runtime.lua":
        new_content, count = re.subn(r'self\.statusLine\s+or\s+["\']Please wait\.\.\.["\']', r'self.statusLine or "@i18n(widgets.dashboard.please_wait_for_telemetry)@"', content)
        if count > 0:
            content = new_content
            changed = True
            
    if changed:
        try:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(content)
        except Exception as e:
            print(f"[PRECOMPILE] Error writing {file_path}: {e}")

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    
    root = Path(args.root)
    for p in root.rglob('*.lua'):
        if p.is_file():
            process_file(p)

if __name__ == '__main__':
    main()
