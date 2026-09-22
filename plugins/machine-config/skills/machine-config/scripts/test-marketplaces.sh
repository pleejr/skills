#!/usr/bin/env bash
# test-marketplaces.sh — fixture pass over remote-marketplaces.sh. Touches nothing real: a
# throwaway CLAUDE_CONFIG_DIR and throwaway git checkouts under mktemp, removed at the end.
#
# Every assertion was proven able to fail by mutating the SUBJECT ($SUBJECT re-points at a
# mutated copy): dropping the origin lookup, the repos.txt fallback, the github parse, the
# autoUpdate write, the known_marketplaces rewrite, the --check exit, the --dry-run no-write
# rule, and the opt-out each redden exactly the lines naming them.
#
# Usage: scripts/test-marketplaces.sh          (exit 0 = every guard held)
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${SUBJECT:-$here/remote-marketplaces.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cfg"
fail=0
ck() { if [ "$1" = 0 ]; then printf '  ok   %s\n' "$2"; else printf '  FAIL %s\n' "$2"; fail=1; fi; }
run() { out="$("$S" "$@" 2>&1)"; rc=$?; }
src() { jq -c --arg n "$2" '.extraKnownMarketplaces[$n].source' "$1"; }

# Fixtures: a checkout with a github origin, one with a non-github origin, a path that does
# not exist but is named in repos.txt, and a plain directory with no git at all.
git init -q "$T/gh" && git -C "$T/gh" remote add origin git@github.com:someone/mkt.git
git init -q "$T/other" && git -C "$T/other" remote add origin https://git.example.com/team/mkt.git
mkdir -p "$T/plain"
printf '# repos\n# repos-dir: ~/x\ngone\thttps://github.com/someone/gone.git\n' > "$T/repos.txt"
reset() {
  rm -rf "$CLAUDE_CONFIG_DIR"; mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
  cat > "$CLAUDE_CONFIG_DIR/settings.json" <<EOF
{
  "theme": "dark — kept",
  "extraKnownMarketplaces": {
    "gh":    {"source": {"source": "directory", "path": "$T/gh"}},
    "other": {"source": {"source": "directory", "path": "$T/other"}},
    "gone":  {"source": {"source": "directory", "path": "$T/nowhere/gone"}},
    "plain": {"source": {"source": "directory", "path": "$T/plain"}},
    "remote":{"source": {"source": "github", "repo": "a/b"}}
  }
}
EOF
  cat > "$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json" <<EOF
{"gh": {"source": {"source": "directory", "path": "$T/gh"}, "installLocation": "$T/gh"}}
EOF
}
SJ="$CLAUDE_CONFIG_DIR/settings.json"; KJ="$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"

# --- 1. --check reports and writes nothing -----------------------------------------------
reset; before="$(cat "$SJ")"
run --check --repos "$T/repos.txt"
[ "$rc" -eq 1 ]; ck $? "--check: exits 1 when a directory marketplace has a remote"
[ "$(cat "$SJ")" = "$before" ]; ck $? "--check: settings.json untouched"

# --- 2. --dry-run writes nothing ---------------------------------------------------------
run --dry-run --repos "$T/repos.txt"
[ "$rc" -eq 0 ] && [ "$(cat "$SJ")" = "$before" ]; ck $? "--dry-run: exits 0, settings.json untouched"

# --- 3. the rewrite ----------------------------------------------------------------------
run --repos "$T/repos.txt"
[ "$rc" -eq 0 ]; ck $? "write: exits 0"
[ "$(src "$SJ" gh)" = '{"source":"github","repo":"someone/mkt"}' ]; ck $? "write: github origin -> github source"
[ "$(src "$SJ" other)" = '{"source":"git","url":"https://git.example.com/team/mkt.git"}' ]; ck $? "write: other origin -> git source"
[ "$(src "$SJ" gone)" = '{"source":"github","repo":"someone/gone"}' ]; ck $? "write: missing path resolved from repos.txt"
[ "$(jq -r '.extraKnownMarketplaces.plain.source.source' "$SJ")" = directory ]; ck $? "write: no remote -> left local"
printf '%s' "$out" | grep -q 'plain: local'; ck $? "write: unresolved marketplace is named"
[ "$(src "$SJ" remote)" = '{"source":"github","repo":"a/b"}' ]; ck $? "write: already-remote entry unchanged"
[ "$(jq -r '.extraKnownMarketplaces.gh.autoUpdate' "$SJ")" = true ]; ck $? "write: autoUpdate set on converted"
[ "$(jq -r '.extraKnownMarketplaces.plain.autoUpdate' "$SJ")" = null ]; ck $? "write: autoUpdate not set on unconverted"
grep -q 'dark — kept' "$SJ"; ck $? "write: unrelated keys kept, non-ASCII unescaped"
[ "$(jq -c .gh.source "$KJ")" = '{"source":"github","repo":"someone/mkt"}' ]; ck $? "write: known_marketplaces source rewritten"
[ "$(jq -r '.gh.installLocation' "$KJ")" = "$CLAUDE_CONFIG_DIR/plugins/marketplaces/gh" ]; ck $? "write: known_marketplaces installLocation moved off the checkout"
[ "$(jq -r '.gh.autoUpdate' "$KJ")" = true ]; ck $? "write: known_marketplaces autoUpdate set"
printf '%s' "$out" | grep -q 'claude plugin marketplace update gh'; ck $? "write: prints the fetch step"

# --- 4. idempotent -----------------------------------------------------------------------
run --check --repos "$T/repos.txt"
[ "$rc" -eq 0 ]; ck $? "after write: --check exits 0"

# --- 5. opt-out --------------------------------------------------------------------------
reset; before="$(cat "$SJ")"
MC_KEEP_DIRECTORY_MARKETPLACES=1 "$S" --repos "$T/repos.txt" >/dev/null 2>&1
[ "$(cat "$SJ")" = "$before" ]; ck $? "opt-out: MC_KEEP_DIRECTORY_MARKETPLACES=1 writes nothing"

exit "$fail"
