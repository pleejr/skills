#!/usr/bin/env python3
"""Find, and optionally rewrite, every reference to a renamed skill.

A rename that leaves an old name behind in another skill's description breaks
routing silently: "Distinct from `old-name`" points at nothing, and the model
loses the disambiguation it was written to provide. So the sweep classifies
each hit instead of replacing text blindly:

  exact     unambiguous references — `old`, [[old]], plugin:old, /old,
            skills/old/, `name: old`, trigger-eval-sets/old*.json.
            --apply rewrites these.
  ambiguous the bare word, e.g. "after the checkpoint". Reported, never
            rewritten: it may be English, not a name.
  links     under a dated-record path (memory/, projects/): only [[old]] links
            are rewritten, so the graph still resolves; the prose is left as
            written, because it reports what happened under the old name.
  history   any hit under a history path (log.md, log/, proposals/,
            CHANGELOG.md, raw/, references/trigger-eval-results/). Never
            rewritten: a dated record of what happened under the old name
            stays true.

Usage:
  rename_sweep.py --map map.json --root <dir> [--root <dir> ...] [--apply]

map.json: [{"plugin": "craft", "old": "eli5", "new": "explain"}, ...]

Exit status: 0 nothing left in the exact class; 1 exact hits remain (report
mode) or a map error; 2 usage error.
"""
import argparse, json, pathlib, re, sys

HISTORY = re.compile(r"(^|/)(log\.md|log/|proposals/|CHANGELOG\.md|PROPOSALS\.md|raw/|"
                     r"references/trigger-eval-results/)")
LINKS_ONLY = re.compile(r"(^|/)(memory|projects)/")
KEEP_HIDDEN = {".claude-plugin", ".github", ".githooks"}
SKIP_DIRS = {"node_modules", "__pycache__"}
TEXT_EXT = {".md", ".json", ".sh", ".py", ".yml", ".yaml", ".toml", ".txt", ""}
B = r"(?<![\w-])"  # a skill name is hyphenated, so '-' counts as part of the word
E = r"(?![\w-])"


def patterns(plugin, old, new, links_only=False):
    o = re.escape(old)
    p = re.escape(plugin)
    link = (rf"\[\[{o}(\||\]\])", rf"[[{new}\1")
    if links_only:
        return [link]
    pats = [  # (regex, replacement); order matters: most specific first
        (rf"{B}{p}:{o}{E}", f"{plugin}:{new}"),
        link,
        (rf"(?<=skills/){o}(?=/)", new),
        (rf"(?m)^name: {o}\s*$", f"name: {new}"),
        (rf"(?<=trigger-eval-sets/){o}(?=(-[\w-]+)?\.json)", new),
    ]
    if old != plugin:  # else `old` and /old name the plugin, which keeps its name
        pats += [(rf"`{o}`", f"`{new}`"), (rf"(?<![\w/-])/{o}{E}", f"/{new}")]
    return pats


def check_map(entries):
    errors, seen_new = [], {}
    olds = {(e["plugin"], e["old"]) for e in entries}
    for e in entries:
        if e["old"] == e["new"]:
            continue
        key = (e["plugin"], e["new"])
        if key in seen_new:
            errors.append(f"{e['plugin']}: '{e['new']}' is the new name of both "
                          f"'{seen_new[key]}' and '{e['old']}'")
        seen_new[key] = e["old"]
        if key in olds:
            errors.append(f"{e['plugin']}: '{e['new']}' is still the old name of another "
                          "skill in this map; rename in two passes")
    return errors


def files(roots):
    for root in roots:
        for f in pathlib.Path(root).rglob("*"):
            rel_parts = f.relative_to(root).parts
            if any(part in SKIP_DIRS or (part.startswith(".") and part not in KEEP_HIDDEN)
                   for part in rel_parts[:-1]) or not f.is_file():
                continue
            if f.suffix not in TEXT_EXT or f.name.endswith(".bak") or ".bak." in f.name:
                continue
            yield root, f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True)
    ap.add_argument("--root", action="append", required=True)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    entries = [e for e in json.loads(pathlib.Path(a.map).read_text()) if e["old"] != e["new"]]
    errs = check_map(entries)
    if errs:
        print("map errors:\n  " + "\n  ".join(errs))
        return 1
    def comp(e, lo):
        return [(re.compile(r), s) for r, s in patterns(e["plugin"], e["old"], e["new"], lo)]
    compiled = [(e, {False: comp(e, False), True: comp(e, True)},
                 re.compile(rf"{B}{re.escape(e['old'])}{E}")) for e in entries]

    counts = {"exact": 0, "ambiguous": 0, "links": 0, "history": 0}
    for root, f in files(a.root):
        try:
            text = f.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        rel = str(f.relative_to(root))
        is_hist = bool(HISTORY.search(rel))
        links_only = bool(LINKS_ONLY.search(rel))
        new_text = text
        for e, by_scope, bare in compiled:
            pats = by_scope[links_only]
            for n, line in enumerate(text.splitlines(), 1):
                if not bare.search(line):
                    continue
                exact = any(r.search(line) for r, _ in pats)
                cls = ("history" if is_hist else
                       ("links" if links_only and exact else "exact" if exact else "ambiguous"))
                counts[cls] += 1
                print(f"{cls:9} {e['old']} -> {e['new']}  {root}/{rel}:{n}: {line.strip()[:140]}")
            if a.apply and not is_hist:
                for r, s in pats:
                    new_text = r.sub(s, new_text)
        if a.apply and new_text != text:
            f.write_text(new_text)

    print(f"\nexact {counts['exact']} · links {counts['links']} · ambiguous {counts['ambiguous']} · "
          f"history {counts['history']}"
          + ("  (exact class rewritten)" if a.apply else ""))
    return 0 if a.apply or counts["exact"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
