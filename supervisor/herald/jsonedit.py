"""Surgical JSON entry rewriter: replace single entries (objects with an "id") inside a JSON file's text without
reformatting the rest, so library diffs stay one line per changed entry. Used by tag_library.py."""
import json, re


def find_object(raw, start):
    """raw[start] is '{': return the index after its matching '}' (string-aware)."""
    depth, i, n, ins = 0, start, len(raw), False
    while i < n:
        c = raw[i]
        if ins:
            if c == '\\': i += 2; continue
            if c == '"': ins = False
        elif c == '"': ins = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return i + 1
        i += 1
    raise ValueError("unbalanced")


def entry_spans(raw):
    """yield (id, start, end) for every object that has an "id" key as one of its own keys"""
    for m in re.finditer(r'"id"\s*:\s*"((?:[^"\\]|\\.)*)"', raw):
        # walk back to the opening brace of the object that owns this key
        depth, i, ins = 0, m.start() - 1, False
        while i >= 0:
            c = raw[i]
            if c == '"':
                # count preceding backslashes to know if escaped
                k, bs = i - 1, 0
                while k >= 0 and raw[k] == '\\': bs += 1; k -= 1
                if bs % 2 == 0: ins = not ins
            elif not ins:
                if c == '}': depth += 1
                elif c == '{':
                    if depth == 0: break
                    depth -= 1
            i -= 1
        yield json.loads('"' + m.group(1) + '"'), i, find_object(raw, i)


def dump_like(obj, old_text):
    """serialize obj in the style of old_text (one line, or indented like the original)"""
    if '\n' not in old_text:
        sep = (",", ":") if re.search(r'"id":"', old_text) else (", ", ": ")
        return json.dumps(obj, ensure_ascii=False, separators=sep)
    lines = old_text.split('\n')
    ind_close = len(lines[-1]) - len(lines[-1].lstrip(' '))
    ind_inner = (len(lines[1]) - len(lines[1].lstrip(' '))) - ind_close if len(lines) > 1 else 1
    s = json.dumps(obj, ensure_ascii=False, indent=max(1, ind_inner))
    # short string lists (fit, when) stay on one line
    s = re.sub(r'\[\s*\n\s*("[^"\n]{0,40}"(?:,\s*\n\s*"[^"\n]{0,40}")*)\s*\n\s*\]', lambda m: '[' + re.sub(r',\s*\n\s*', ', ', m.group(1)) + ']', s)
    return s.replace('\n', '\n' + ' ' * ind_close)


def rewrite(raw, updates):
    """updates: {id: new_obj}; returns new raw text"""
    spans = [(i, s, e) for i, s, e in entry_spans(raw) if i in updates]
    out, last = [], 0
    for i, s, e in sorted(spans, key=lambda x: x[1]):
        if s < last: continue   # nested inside an already replaced object
        out.append(raw[last:s]); out.append(dump_like(updates[i], raw[s:e])); last = e
    out.append(raw[last:])
    return ''.join(out)
