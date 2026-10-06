#!/usr/bin/env bash
# verify.sh — after a restore, ask whether the config WORKS, not whether the files arrived.
# Deterministic; NEVER spawns `claude`.
#
# WHY THIS EXISTS. A restore that copies every byte correctly can still hand back a machine
# whose modes are off. The since-retired `expand-acronyms` was the worked example: settings.json carried the
# wired hook, the hook's script was restored, and the two files it reads were not — so the
# hook ran, found nothing, correctly treated missing-as-off, and exited 0. Every file the
# restore knew about was present and the mode was gone. Presence checks cannot see that;
# only asking the component itself can.
#
# HOW IT DISCOVERS WHAT TO CHECK. From settings.json — the scripts it actually points at, and
# the hooks.json of every plugin it enables —
# never from a list maintained here. A hand-maintained list of things-to-verify would rot in
# exactly the way MC_FILES did before skill-state/ became a captured directory, and it would
# rot silently, which is the failure this script exists to catch.
#
# WHY SCRIPTS MUST OPT IN. A hook command is arbitrary code the user wired for their own
# purposes; running one with an unexpected argument to see what happens could have side
# effects a verification pass has no business causing. So a script is only invoked if it
# carries the marker below, which is a deliberate declaration that `selfcheck` is safe,
# read-only, and meaningful.
#
# THE CONTRACT for a participating script:
#   - carry the literal marker  # machine-config: selfcheck  somewhere in the file
#   - accept a `selfcheck` argument, take no other input, and change nothing
#   - print one short line per finding, each prefixed `ok:` or `degraded:`
#   - exit 0 when healthy, non-zero when degraded
#
# Usage:
#   scripts/verify.sh            report; exit 1 if anything is degraded
#   scripts/verify.sh --quiet    print only problems (for a session check)
set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
CFG="$(mc_cfg)"
SETTINGS="$CFG/settings.json"
MARKER='# machine-config: selfcheck'

quiet=0
case "${1:-}" in
  --quiet) quiet=1 ;;
  "") ;;
  *) echo "verify: unknown arg '$1' (try: --quiet)" >&2; exit 2 ;;
esac

say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }
problems=0
note_problem() { printf '%s\n' "$*"; problems=$((problems + 1)); }

[ -f "$SETTINGS" ] || { note_problem "verify: no settings.json at $SETTINGS — nothing is wired"; exit 1; }

# Pull the script paths out of hook and statusLine commands. Real commands are messy — inline
# pipelines, `bash '/path/x.sh' arg`, an env assignment before the path — so rather than parse
# shell, take every absolute path token that looks like a script. Commands that are pure inline
# shell yield nothing, which is correct: there is no script of ours to check.
if ! command -v python3 >/dev/null 2>&1; then
  note_problem "verify: python3 not found — cannot read settings.json; check hooks by hand"
  exit 1
fi

scripts="$(python3 - "$SETTINGS" <<'PY'
import json, re, shlex, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"!parse {e}", file=sys.stderr); raise SystemExit(3)

cmds = []
sl = cfg.get("statusLine")
if isinstance(sl, dict) and sl.get("command"): cmds.append(sl["command"])
elif isinstance(sl, str): cmds.append(sl)
def hook_cmds(hooks, root=None):
    for entries in (hooks or {}).values():
        for e in entries or []:
            for h in e.get("hooks") or []:
                c = h.get("command")
                if c and root: c = c.replace("${CLAUDE_PLUGIN_ROOT}", root)
                if c: cmds.append(c)
hook_cmds(cfg.get("hooks"))

# Enabled plugins carry hooks too, in <root>/hooks/hooks.json. A directory marketplace runs
# the plugin in place from its source, not from the cache copy install writes, so that is the
# root to check; any other source runs from its recorded install path.
import os
pdir = os.path.join(os.path.dirname(sys.argv[1]), "plugins")
def load(path):
    try: return json.load(open(path))
    except Exception: return {}
known = load(os.path.join(pdir, "known_marketplaces.json"))
installed = load(os.path.join(pdir, "installed_plugins.json"))
installed = installed.get("plugins", installed)
for pid, on in (cfg.get("enabledPlugins") or {}).items():
    if on is not True or "@" not in pid: continue
    name, mkt = pid.rsplit("@", 1)
    root = None
    src = (known.get(mkt) or {}).get("source") or {}
    if src.get("source") == "directory":
        for p in load(os.path.join(src.get("path", ""), ".claude-plugin", "marketplace.json")).get("plugins", []):
            if p.get("name") == name and isinstance(p.get("source"), str):
                root = os.path.normpath(os.path.join(src["path"], p["source"]))
    if not root:
        for inst in installed.get(pid) or []:
            root = inst.get("installPath") or root
    if not root or not os.path.isdir(root):
        print(f"!plugin {pid}"); continue
    hook_cmds(load(os.path.join(root, "hooks", "hooks.json")).get("hooks"), root)

seen, out = set(), []
for c in cmds:
    try: toks = shlex.split(c)
    except ValueError: toks = re.findall(r"'[^']*'|\"[^\"]*\"|\S+", c)
    for t in toks:
        t = t.strip("'\"")
        # An absolute path that is plausibly a script of ours. $-bearing tokens are unresolved
        # shell, and a trailing subcommand like `inject` is an argument, not a path.
        if t.startswith("/") and "$" not in t and (t.endswith(".sh") or "/bin/" in t or "/hooks/" in t):
            if t not in seen:
                seen.add(t); out.append(t)
print("\n".join(out))
PY
)" || { note_problem "verify: settings.json is not valid JSON — hooks will not load"; exit 1; }

say "=== wired scripts exist and can run ==="
n_scripts=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$s" in "!plugin "*)
    note_problem "  MISSING  ${s#!plugin } — enabled in settings, but no installed copy to run its hooks from"
    continue;;
  esac
  n_scripts=$((n_scripts + 1))
  if [ ! -e "$s" ]; then
    note_problem "  MISSING  $s — a hook points here and nothing is there"
  elif [ ! -x "$s" ]; then
    note_problem "  NOT EXEC $s — restored without its executable bit; fails on every trigger"
  else
    say "  ok       $s"
  fi
done <<EOF
$scripts
EOF
[ "$n_scripts" -eq 0 ] && say "  (no script paths referenced — hooks are inline shell only)"

# The part presence checks cannot do: ask each participating component whether it is actually
# working. Only marker-carrying scripts are run; see the contract at the top.
say
say "=== components report their own state ==="
n_checks=0
while IFS= read -r s; do
  [ -n "$s" ] && [ -x "$s" ] || continue
  grep -qF "$MARKER" "$s" 2>/dev/null || continue
  n_checks=$((n_checks + 1))
  out="$("$s" selfcheck </dev/null 2>&1)"; rc=$?
  label="$(basename "$s")"
  # A degraded component is ONE problem however many lines it needs to explain itself —
  # counting lines would make a wordy check look like a worse outage than a terse one.
  [ "$rc" -eq 0 ] || problems=$((problems + 1))
  [ -n "$out" ] || out="selfcheck failed (exit $rc, no output)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$rc" -eq 0 ]; then say "  $label: $line"; else printf '  %s: %s\n' "$label" "$line"; fi
  done <<EOF
$out
EOF
done <<EOF
$scripts
EOF
if [ "$n_checks" -eq 0 ]; then
  say "  (none of the wired scripts implement selfcheck — see the contract in this file)"
fi

say
if [ "$problems" -eq 0 ]; then
  say "verify: config is wired and every participating component reports healthy"
  exit 0
fi
echo "verify: $problems problem(s) above — the restore is not done until these are resolved"
exit 1
