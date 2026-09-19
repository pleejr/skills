#!/usr/bin/env bash
# acronyms.sh — state, skip-list and UserPromptSubmit hook for the expand-acronyms mode.
#
# Deterministic: bash + two text files + one guarded settings.json merge. NEVER spawns
# `claude`, so it is safe to wire as a lifecycle hook (see the fork-bomb rule in the
# wiki-engine's CLAUDE.md — the danger is a hook whose child can re-trigger the same event).
#
# FAIL-CLOSED TOWARD SILENCE. Every unreadable/missing/garbled state is treated as "off".
# The failure mode of guessing "on" is a hook that injects an unwanted directive into every
# prompt with no obvious cause; the failure mode of guessing "off" is a mode the user turns
# on again. Only the second is recoverable in one step.
#
# ALWAYS EXITS 0 on `inject`. A non-zero UserPromptSubmit hook surfaces as an error on the
# user's turn; a formatting preference must never be able to interrupt work.
#
# Usage:
#   acronyms.sh on | off | status | list
#   acronyms.sh skip <ACRONYM>...      mark as already-known (never expanded)
#   acronyms.sh unskip <ACRONYM>...    resume expanding it
#   acronyms.sh wire | unwire          add/remove the hook in ~/.claude/settings.json
#   acronyms.sh inject                 the hook body (prints the directive when on)
#   acronyms.sh selfcheck              report whether the mode actually works (see below)
#
# machine-config: selfcheck
# The marker above opts this script into `machine-config`'s post-restore verification, which
# runs `selfcheck` on the scripts settings.json points at. Read-only, no side effects.
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Durable mode lives in skill-state/, NOT loose in ~/.claude. That directory is captured
# wholesale by the machine-config backup, while the top level is a hand-maintained filename
# list; state parked at the top level is therefore dropped from a snapshot silently, and a
# restored machine gets the wired hook without the mode it reads — present wiring, absent
# behavior, green checkmark. Any skill with durable state should write it here.
STATE_DIR="$CLAUDE_DIR/skill-state"
STATE="$STATE_DIR/acronyms.state"
KNOWN="$STATE_DIR/acronyms-known.txt"
SETTINGS="$CLAUDE_DIR/settings.json"
# Resolve symlinks on the FILE, not just its directory: the plugin's bin/acronyms is a
# symlink to this script, and a directory-only resolve lands SELF in bin/, which puts every
# path derived from it (the plugin's hooks file) in the wrong place.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SELF="$(cd -P "$(dirname "$_src")" && pwd)/$(basename "$_src")"

die() { printf '%s\n' "$*" >&2; exit 2; }

# One-time move from the pre-skill-state layout. Runs on every invocation because there is no
# install step to hang it on, and `inject` is the only path guaranteed to run — so it must be
# safe there: it writes nothing to stdout (which would land in the model's context) and can
# never fail the script. Legacy is moved only when the new path is absent, so a migrated file
# is never overwritten by a stale leftover; concurrent sessions racing the same `mv` are
# harmless, since the loser simply finds the source gone.
migrate_legacy_state() {
  local legacy new pair
  for pair in "acronyms.state:$STATE" "acronyms-known.txt:$KNOWN"; do
    legacy="$CLAUDE_DIR/${pair%%:*}"; new="${pair#*:}"
    [ -f "$legacy" ] || continue
    [ -e "$new" ] && continue
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    mv "$legacy" "$new" 2>/dev/null || true
  done
  return 0
}
migrate_legacy_state

# Uppercase and strip anything that is not plausibly part of an acronym, so that a term
# picked up verbatim from a sentence ("API," / "`JWT`") lands in the file in one canonical
# form. Without this the list silently accumulates near-duplicates that never match.
normalize() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9&./+-'
}

is_on() { [ -r "$STATE" ] && [ "$(tr -d '[:space:]' <"$STATE" 2>/dev/null)" = "on" ]; }

known_terms() {
  [ -r "$KNOWN" ] || return 0
  sed 's/#.*//' "$KNOWN" | tr ',' '\n' | tr -d '[:blank:]' | grep -v '^$' || true
}

# Match the invocation, not the physical path: a hook wired by hand through the
# ~/.claude/skills symlink is still this hook.
# Plugin mode: the hook ships in the acronyms plugin's hooks/hooks.json, so enabling the
# plugin IS wiring it and settings.json never carries the entry. Decided by whether the plugin
# is ENABLED, never by where this file sits: during the migration the same file is also
# reached through the skills/expand-acronyms compatibility symlink on machines still wired
# by hand, and those must keep wire/unwire.
plugin_mode() { grep -qE '"acronyms@[^"]*"[[:space:]]*:[[:space:]]*true' "$SETTINGS" 2>/dev/null; }

hook_wired() {
  plugin_mode && return 0
  [ -r "$SETTINGS" ] || return 1
  grep -qF "acronyms.sh inject" "$SETTINGS" 2>/dev/null
}

cmd="${1:-status}"; shift 2>/dev/null || true

case "$cmd" in

on|off)
  mkdir -p "$STATE_DIR" || die "cannot write $STATE_DIR"
  printf '%s\n' "$cmd" >"$STATE" || die "cannot write $STATE"
  printf 'acronym expansion: %s\n' "$cmd"
  if [ "$cmd" = on ] && ! hook_wired; then
    printf 'note: hook not wired — mode holds for this session only (run: %s wire)\n' "$SELF"
  fi
  ;;

status)
  is_on && s=on || s=off
  hook_wired && w=wired || w="not wired"
  printf 'mode: %s\nhook: %s\nskip-list: %s term(s) in %s\n' \
    "$s" "$w" "$(known_terms | wc -l | tr -d ' ')" "$KNOWN"
  ;;

selfcheck)
  # Answers "does the mode work", which is a different question from "are the files there".
  # The case worth catching is wired-but-stateless: settings.json restored with the hook, no
  # mode file behind it, so every prompt runs a hook that reads nothing and silently expands
  # nothing. That combination is indistinguishable from a healthy machine by inspection —
  # the hook is present, the script runs, the exit code is 0.
  rc=0
  if hook_wired; then
    if [ -r "$STATE" ]; then
      is_on && printf 'ok: hook wired, mode on, %s term(s) on the skip-list\n' "$(known_terms | wc -l | tr -d ' ')" \
             || printf 'ok: hook wired, mode deliberately off\n'
    else
      printf 'degraded: hook wired but no mode state at %s\n' "$STATE"
      printf 'degraded: every prompt runs a hook that reads nothing and expands nothing; fix with `%s on`\n' "$SELF"
      rc=1
    fi
  elif is_on; then
    printf 'ok: mode on, hook not wired — holds for a session, lost on compaction\n'
  else
    printf 'ok: mode off and not wired (nothing to restore)\n'
  fi
  # A skip-list that exists but cannot be read would expand terms the user marked known —
  # a quieter wrong, worth naming separately from the mode itself.
  if [ -e "$KNOWN" ] && [ ! -r "$KNOWN" ]; then
    printf 'degraded: skip-list at %s is unreadable — known terms would be expanded again\n' "$KNOWN"
    rc=1
  fi
  exit "$rc"
  ;;

list)
  n="$(known_terms | sort -u)"
  [ -n "$n" ] && printf '%s\n' "$n" || printf '(skip-list empty — everything gets expanded)\n'
  ;;

skip)
  [ $# -gt 0 ] || die "usage: acronyms.sh skip <ACRONYM>..."
  mkdir -p "$STATE_DIR"
  [ -e "$KNOWN" ] || printf '# Acronyms this user already knows — never expanded.\n# One per line; managed by the expand-acronyms skill.\n' >"$KNOWN"
  added=""
  for raw in "$@"; do
    t="$(normalize "$raw")"; [ -n "$t" ] || continue
    if known_terms | grep -qxF "$t"; then continue; fi
    printf '%s\n' "$t" >>"$KNOWN" || die "cannot write $KNOWN"
    added="$added $t"
  done
  [ -n "$added" ] && printf 'skipping now:%s\n' "$added" || printf 'already on the skip-list\n'
  ;;

unskip)
  [ $# -gt 0 ] || die "usage: acronyms.sh unskip <ACRONYM>..."
  [ -w "$KNOWN" ] || die "no skip-list at $KNOWN"
  for raw in "$@"; do
    t="$(normalize "$raw")"; [ -n "$t" ] || continue
    # Dotfile temp: skill-state/ is captured wholesale, and the backup skips dotfiles — so a
    # temp left behind by a crashed rewrite is never snapshotted and never restored.
    tmp="$STATE_DIR/.acronyms-known.tmp.$$"
    grep -vxF "$t" "$KNOWN" >"$tmp" 2>/dev/null || true
    mv "$tmp" "$KNOWN" || die "cannot rewrite $KNOWN"
    printf 'expanding again: %s\n' "$t"
  done
  ;;

inject)
  # Hook body. Reads (and ignores) the hook JSON on stdin. Stdout is added to the model's
  # context for this turn; silence when off means zero footprint on an unused mode.
  cat >/dev/null 2>&1 || true
  is_on || exit 0
  # paste -d takes a cycling LIST of delimiters, not a literal string — ", " would alternate
  # comma and space between terms. Join on one char, then space it out.
  skips="$(known_terms | sort -u | paste -sd, - 2>/dev/null | sed 's/,/, /g')"
  cat <<EOF
<acronym-expansion mode="on">
Spell out every acronym, initialism, and domain abbreviation on its FIRST use in each reply,
then use the bare form for the rest of that reply — e.g. "CI (continuous integration)".
Per reply, not per session: a reader looking at one message alone must not have to scroll up.

Applies to prose, headings, bullets, tables and commit messages. Never rewrite the inside of
code, identifiers, file paths, URLs, command lines, flags, env var names, literal tool output,
or anything quoted from the user — gloss those alongside instead: the \`--tls-verify\` flag
(transport layer security).

Do not invent an expansion. If unsure, write "SLSA (expansion uncertain)" or ask; if the
letters are simply the name and any expansion would be historical or disputed, say so once.
EOF
  if [ -n "$skips" ]; then
    printf 'Already known to this user — leave these BARE, never expand: %s\n' "$skips"
  fi
  cat <<EOF
If the user marks an acronym as known ("skip X", "I know what X means", "stop expanding that"),
run: $SELF skip X — then honour it for the remainder of the current reply too.
</acronym-expansion>
EOF
  exit 0
  ;;

wire|unwire)
  if plugin_mode; then
    printf 'plugin mode: the hook ships with the acronyms plugin; %s it with /plugin instead\n' \
      "$([ "$cmd" = wire ] && echo enable || echo disable)" >&2
    exit 2
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 required to edit settings.json"
  [ -e "$SETTINGS" ] || printf '{}\n' >"$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.expand-acronyms" || die "cannot back up $SETTINGS"
  # Merge, never overwrite: only this script's own UserPromptSubmit entry is added or
  # removed. Any other hook in the file is left byte-identical.
  python3 - "$SETTINGS" "$SELF" "$cmd" <<'PY' || die "settings.json unchanged (see $SETTINGS.bak.expand-acronyms)"
import json, sys
path, self_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = json.load(f)
hooks = cfg.setdefault("hooks", {})
entries = hooks.setdefault("UserPromptSubmit", [])
def mine(e):
    # Same rule as hook_wired: an entry is ours if it invokes `acronyms.sh inject`, whatever path.
    return any("acronyms.sh inject" in (h.get("command") or "") for h in e.get("hooks", []))
kept = [e for e in entries if not mine(e)]
if mode == "wire":
    kept.append({"hooks": [{"type": "command",
                            "command": f"{self_path} inject",
                            "timeout": 5}]})
hooks["UserPromptSubmit"] = kept
if not kept:
    del hooks["UserPromptSubmit"]
if not hooks:
    del cfg["hooks"]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"{mode}d: UserPromptSubmit -> acronyms.sh inject")
PY
  printf 'backup: %s\n' "$SETTINGS.bak.expand-acronyms"
  ;;

*)
  die "unknown command: $cmd (try: on off status list skip unskip wire unwire inject selfcheck)"
  ;;
esac
