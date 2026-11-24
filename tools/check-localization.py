#!/usr/bin/env python3
"""Checks the localization:
- String Catalogs: every string is translated to every language, format specifiers match
  the key, plural variations cover the language's categories;
- Swift sources: no hard-coded Cyrillic string literals outside comments (English is the
  development language; mark an intentional one with `// l10n-ignore`, a whole file with
  `// l10n-ignore-file`).

    tools/check-localization.py            # all *.xcstrings and *.swift under app/
Exit 1 on any problem (used by CI).
"""
import glob
import json
import re
import sys

LANGS = ["uk"]
PLURALS = {"en": {"one", "other"}, "uk": {"one", "few", "many", "other"}}
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA])|%#@\w+@")


def specs(s):
    """Specifier types in order (positional or not), %% ignored."""
    s = s.replace("%%", "")
    return sorted(m.group(1) or "#" for m in SPEC.finditer(s))


def units(loc):
    """(value, plural categories or None) for a localization entry."""
    if "stringUnit" in loc and "substitutions" not in loc:
        yield loc["stringUnit"]["value"], None
    if "substitutions" in loc:
        yield loc["stringUnit"]["value"], None
        for sub in loc["substitutions"].values():
            p = sub.get("variations", {}).get("plural", {})
            yield None, set(p)
    if "variations" in loc:
        p = loc["variations"].get("plural", {})
        for v in p.values():
            yield v["stringUnit"]["value"], set(p)


def check(path):
    problems = []
    cat = json.load(open(path))
    for key, entry in cat["strings"].items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        locs = entry.get("localizations", {})
        for lang in LANGS:
            loc = locs.get(lang)
            if not loc:
                problems.append(f"{key!r}: no {lang} translation")
                continue
            for value, cats in units(loc):
                if cats is not None and not PLURALS[lang] <= cats:
                    problems.append(f"{key!r}: {lang} plural lacks {sorted(PLURALS[lang] - cats)}")
                if value is None:
                    continue
                state = None
                if "stringUnit" in loc:
                    state = loc["stringUnit"].get("state")
                if state not in (None, "translated"):
                    problems.append(f"{key!r}: {lang} state is {state}")
                if "%#@" in value:
                    continue  # substitutions: checked through their variations
                if specs(value) != specs(key) and not (cats and value.count("%") < key.count("%")):
                    problems.append(f"{key!r}: {lang} specifiers {specs(value)} != key {specs(key)}")
    return len(cat["strings"]), list(dict.fromkeys(problems))


CYR_LITERAL = re.compile(r'"(?:[^"\\]|\\.)*[\u0400-\u04FF](?:[^"\\]|\\.)*"')


def code_part(line):
    """The line without a trailing // comment (a // inside a string literal is kept)."""
    quoted = False
    for i, c in enumerate(line):
        if c == '"' and (i == 0 or line[i - 1] != "\\"):
            quoted = not quoted
        elif not quoted and line.startswith("//", i):
            return line[:i]
    return line


def check_sources():
    problems = []
    for path in sorted(glob.glob("app/**/*.swift", recursive=True)):
        if "/build/" in path or "/.build/" in path or "/Tests/" in path:
            continue
        text = open(path, encoding="utf-8").read()
        if "l10n-ignore-file" in text:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if "l10n-ignore" in line or line.lstrip().startswith(("//", "*")):
                continue
            if CYR_LITERAL.search(code_part(line)):
                problems.append(f"{path}:{n}: hard-coded Cyrillic string: {line.strip()[:90]}")
    return problems


def main():
    paths = sys.argv[1:] or sorted(glob.glob("app/**/*.xcstrings", recursive=True))
    failed = False
    for p in paths:
        n, problems = check(p)
        print(f"{p}: {n} strings, {len(problems)} problems")
        for pr in problems:
            print("  -", pr)
        failed |= bool(problems)
    if not sys.argv[1:]:
        problems = check_sources()
        print(f"Swift sources: {len(problems)} hard-coded Cyrillic strings")
        for pr in problems:
            print("  -", pr)
        failed |= bool(problems)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
