#!/usr/bin/env bash
# remote-marketplaces.sh — point every `directory` plugin marketplace that is really a git
# checkout at its remote instead. Deterministic; NEVER spawns `claude`.
#
# WHY. A directory marketplace runs the plugins straight out of a working tree: uncommitted
# edits, a half-finished branch, whatever is checked out is what every session loads, and no
# other machine sees it. A remote source (`github` / `git`) loads the published commit, and
# `autoUpdate` keeps it current. Local is a development mode — use `claude --plugin-dir` for
# that — not the default a restored machine should come back with.
#
# WHERE THE REMOTE COMES FROM. The checkout's own `origin` when the path exists; otherwise the
# snapshot's repos.txt, matched on the directory name. The second is the disaster case: a fresh
# machine is restored BEFORE its repos are cloned, so the path is not there to ask.
#
# Rewrites extraKnownMarketplaces in settings.json and, when present, the same entry in
# plugins/known_marketplaces.json (the record Claude Code already cached) — changing only the
# source, never the marketplace name, so every `<plugin>@<name>` install and enable survives.
# Each converted marketplace also gets `autoUpdate: true` — a remote that is never re-fetched
# pins the machine to the commit of its first clone, which is the staleness this exists to end.
# A marketplace whose remote cannot be determined is left as it is and named.
#
# Opt out with MC_KEEP_DIRECTORY_MARKETPLACES=1 — for a machine that is deliberately
# developing against a local marketplace.
#
# Usage:
#   remote-marketplaces.sh [--repos <repos.txt>] [--dry-run | --check]
#     --dry-run  say what would change, write nothing (exit 0)
#     --check    write nothing; exit 1 if anything would change (for the session banner)
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
CFG="$(mc_cfg)"
repos=""; mode=write
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) repos="${2:-}"; shift 2 ;;
    --repos=*) repos="${1#--repos=}"; shift ;;
    --dry-run) mode=dry; shift ;;
    --check) mode=check; shift ;;
    *) echo "remote-marketplaces: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
[ "${MC_KEEP_DIRECTORY_MARKETPLACES:-0}" = 1 ] && exit 0
[ -f "$CFG/settings.json" ] || exit 0
command -v python3 >/dev/null 2>&1 || { echo "remote-marketplaces: python3 not found; skipped" >&2; exit 0; }

python3 - "$CFG" "$repos" "$mode" <<'PY'
import json, os, re, subprocess, sys
cfg, repos, mode = sys.argv[1], sys.argv[2], sys.argv[3]
sp = os.path.join(cfg, "settings.json")
kp = os.path.join(cfg, "plugins", "known_marketplaces.json")

def load(p):
    try: return json.load(open(p))
    except Exception: return None

settings = load(sp)
if not isinstance(settings, dict):
    print("remote-marketplaces: settings.json is not valid JSON; skipped", file=sys.stderr); sys.exit(0)
known = load(kp) if os.path.isfile(kp) else None

by_name = {}
if repos and os.path.isfile(repos):
    for line in open(repos):
        if line.startswith("#"): continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 2: by_name[parts[0]] = parts[1]

def remote_of(path):
    if os.path.isdir(path):
        try:
            return subprocess.run(["git", "-C", path, "remote", "get-url", "origin"],
                                  capture_output=True, text=True, timeout=10).stdout.strip() or None
        except Exception:
            return None
    return by_name.get(os.path.basename(os.path.normpath(path)))

def source_for(url):
    m = re.match(r"^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?/?$", url)
    if m: return {"source": "github", "repo": m.group(1)}
    return {"source": "git", "url": url}

changes, unresolved = {}, []
for name, entry in (settings.get("extraKnownMarketplaces") or {}).items():
    src = (entry or {}).get("source") or {}
    if src.get("source") != "directory": continue
    url = remote_of(src.get("path", ""))
    if not url: unresolved.append((name, src.get("path", ""))); continue
    changes[name] = source_for(url)

for name, path in unresolved:
    print(f"  {name}: local ({path}) — no remote found, left as is")
if not changes: sys.exit(0)
for name, new in changes.items():
    print(f"  {name}: directory -> {new['source']} {new.get('repo') or new.get('url')}")
if mode == "check": sys.exit(1)
if mode == "dry": sys.exit(0)

def dump(p, obj):
    with open(p, "w") as f: f.write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")

for name, new in changes.items():
    settings["extraKnownMarketplaces"][name]["source"] = new
    settings["extraKnownMarketplaces"][name]["autoUpdate"] = True
dump(sp, settings)
if isinstance(known, dict):
    touched = False
    for name, new in changes.items():
        if isinstance(known.get(name), dict) and (known[name].get("source") or {}).get("source") == "directory":
            known[name]["source"] = new
            known[name]["installLocation"] = os.path.join(cfg, "plugins", "marketplaces", name)
            known[name]["autoUpdate"] = True
            touched = True
    if touched: dump(kp, known)
print("remote-marketplaces: now fetch each from its remote (a script may not run claude):")
for name in changes: print(f"  claude plugin marketplace update {name}")
PY
