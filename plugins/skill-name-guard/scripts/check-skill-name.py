#!/usr/bin/env python3
"""PostToolUse hook: warn when a SKILL.md is written with a non-verb-led name.

Reads the hook payload on stdin. Advisory by design: it can only add context for the
model, never block the write (the file is already written), and any failure to read
or parse exits 0 silently, so a broken guard never breaks an edit.

  check-skill-name.py              hook mode (payload on stdin)
  check-skill-name.py --name NAME  check a name; exit 1 and print why if it fails
"""
import json, os, pathlib, re, sys

DATA = pathlib.Path(os.environ.get("SKILL_NAME_GUARD_DATA") or pathlib.Path(__file__).resolve().parent.parent / "data")


def words(path):
    out = set()
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line.split()[0])
    return out


def verdict(name):
    """None if the name is fine, else a one-paragraph reason."""
    verbs, exempt = words(DATA / "verbs.txt"), words(DATA / "exempt.txt")
    first = name.split("-")[0].lower()
    if first in verbs or name in exempt:
        return None
    return (f"Skill name '{name}' does not start with an approved verb ('{first}' is not on the list). "
            f"Name it <verb> or <verb>-<object>, e.g. 'review-plan' or 'map-blast-radius': the verb says the "
            f"action, the object keeps the words people type, which is what routes a prompt to the skill. "
            f"Approved verbs: {DATA / 'verbs.txt'}. If no verb fits, add one there as its own reviewed change. "
            f"{DATA / 'exempt.txt'} is closed to new skills: it holds names kept after a measured routing loss.")


def frontmatter_name(text):
    m = re.match(r"---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    n = re.search(r"(?m)^name:\s*(\S+)\s*$", m.group(1))
    return n.group(1).strip("\"'") if n else None


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--name":
        why = verdict(sys.argv[2])
        if why:
            print(why)
            return 1
        return 0
    try:
        payload = json.load(sys.stdin)
        path = pathlib.Path(payload["tool_input"]["file_path"])
        if path.name != "SKILL.md" or path.parent.parent.name != "skills":
            return 0
        name = frontmatter_name(path.read_text())
        why = verdict(name) if name else None
    except Exception:
        return 0
    if why:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": why}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
