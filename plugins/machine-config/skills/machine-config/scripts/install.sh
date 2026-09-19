#!/usr/bin/env bash
# install.sh — make backup automatic on this machine. Wires two things, both idempotent:
#
#   1. SessionEnd hook  -> autosave.sh   snapshot + commit + push when a session ends, which
#                                        is when config has settled. This is the one that
#                                        means nobody has to remember to run anything.
#   2. session-checks.d -> session-check.sh   the safety net: if autosave has been failing
#                                        (refused secret, no remote, missing jq), it says so
#                                        at session start. Optional — needs a wiki-engine
#                                        seam; skipped with an explanation if absent.
#   3. session-checks.d -> session-apply.sh   installs shared output styles at session start,
#                                        so a style authored on one machine reaches the other
#                                        without anyone running a command. Linked under the
#                                        name `zz-machine-config-apply.sh` ON PURPOSE: the
#                                        engine runs the drop-ins in glob order, and this one
#                                        must sort AFTER whatever syncs the stores, or it
#                                        applies the state from before the sync.
#
# Neither spawns `claude`; both are plain git, which is the case the no-claude-in-hooks rule
# permits. Editing settings.json is what makes the hook real, so this backs it up first.
#
# Usage:
#   scripts/install.sh            wire all three; with the plugin enabled, unwire them instead
#   scripts/install.sh --remove   unwire all three
#
# Plugin delivery (`machine-config@pleejr`) replaces this script: hooks/hooks.json wires the
# same hooks, and the legacy copies stand down while it is enabled.
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

CFG="$(mc_cfg)"
settings="$CFG/settings.json"
dropin="$CFG/session-checks.d/machine-config.sh"
# 'zz-' is load-bearing; see the header. Renaming it re-opens the ordering bug.
dropin_apply="$CFG/session-checks.d/zz-machine-config-apply.sh"
cmd="$here/autosave.sh"
remove=0
[ "${1:-}" = "--remove" ] && remove=1

# With the machine-config plugin enabled, its hooks/hooks.json carries all three: SessionEnd
# autosave and one SessionStart hook for both checks. Wiring them here as well would run each
# twice, so install becomes the cleanup of this script's own legacy wiring.
if [ "$remove" -eq 0 ] && mc_plugin_enabled machine-config; then
  echo "install: the machine-config plugin is enabled and carries these hooks — removing the legacy wiring instead"
  remove=1
fi

command -v jq >/dev/null 2>&1 || { echo "install: jq is required" >&2; exit 2; }

# ---- 1. SessionEnd hook -------------------------------------------------------------------
[ -f "$settings" ] || echo '{}' > "$settings"
jq empty "$settings" 2>/dev/null || { echo "install: $settings is not valid JSON — fix it first" >&2; exit 2; }

if [ "$remove" -eq 1 ]; then
  # By suffix as well as exact path: an older install wired the skill through the repo's
  # skills/machine-config symlink, so its command names a different path to the same script.
  new="$(jq --arg c "$cmd" '
    if (.hooks.SessionEnd? | type) == "array" then
      .hooks.SessionEnd |= (map(.hooks |= map(select(.command != $c and ((.command // "") | endswith("/machine-config/scripts/autosave.sh") | not)))) | map(select((.hooks|length) > 0)))
    else . end' "$settings")"
  [ "$new" = "$(jq . "$settings")" ] && new=""
else
  # Present already? Leave it alone rather than appending a duplicate on every run.
  if jq -e --arg c "$cmd" '[.. | objects | select(.command? == $c)] | length > 0' "$settings" >/dev/null; then
    new=""
  else
    new="$(jq --arg c "$cmd" '
      .hooks //= {} |
      .hooks.SessionEnd //= [] |
      .hooks.SessionEnd += [{hooks: [{type: "command", command: $c, timeout: 30}]}]' "$settings")"
  fi
fi

if [ -n "${new:-}" ]; then
  cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$new" > "$settings"
  if [ "$remove" -eq 1 ]; then echo "install: removed SessionEnd autosave hook"
  else echo "install: wired SessionEnd autosave hook -> $cmd"; fi
else
  if [ "$remove" -eq 1 ]; then echo "install: SessionEnd autosave hook already absent"
  else echo "install: SessionEnd autosave hook already present"; fi
fi

# ---- 2. session-start drift check (optional) ----------------------------------------------
if [ "$remove" -eq 1 ]; then
  if [ -L "$dropin" ]; then rm -f "$dropin"; echo "install: removed $dropin"; fi
  if [ -L "$dropin_apply" ]; then rm -f "$dropin_apply"; echo "install: removed $dropin_apply"; fi
  exit 0
fi

if [ ! -d "$CFG/session-checks.d" ]; then
  echo "install: no $CFG/session-checks.d — that is a wiki-engine seam, so the session-start"
  echo "         safety net was skipped. Autosave above still runs; you just won't get a"
  echo "         banner if it ever starts failing."
  exit 0
fi
if [ "$(readlink "$dropin" 2>/dev/null)" = "$here/session-check.sh" ]; then
  echo "install: drift check already linked"
else
  ln -snf "$here/session-check.sh" "$dropin"
  echo "install: linked drift check -> $dropin"
fi

# ---- 3. session-start style apply ---------------------------------------------------------
if [ "$(readlink "$dropin_apply" 2>/dev/null)" = "$here/session-apply.sh" ]; then
  echo "install: style apply already linked"
else
  ln -snf "$here/session-apply.sh" "$dropin_apply"
  echo "install: linked style apply -> $dropin_apply"
fi
