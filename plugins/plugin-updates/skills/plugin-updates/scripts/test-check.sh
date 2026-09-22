#!/usr/bin/env bash
# test-check.sh — fixture suite for check.py. Every marketplace is a local git repo; GitHub
# sources are mapped onto them with PLUGIN_UPDATES_GITHUB_BASE, so nothing touches the network.
# Each case asserts the red (an outdated plugin is named) and the control (a current one is not).
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$here/check.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ck() { if [ "$1" -eq 0 ]; then echo "  ok   $2"; else echo "  FAIL $2"; fail=1; fi; }

G="$T/cfg"; GH="$T/gh"; DATA="$T/data"; mkdir -p "$G/plugins" "$GH" "$DATA"
# A fake `claude` on PATH: the check must never run it.
mkdir -p "$T/fakebin"; printf '#!/bin/sh\ntouch "%s/CLAUDE-RAN"\n' "$T" > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
export PATH="$T/fakebin:$PATH" CLAUDE_CONFIG_DIR="$G" CLAUDE_PLUGIN_DATA="$DATA" PLUGIN_UPDATES_GITHUB_BASE="$GH"
unset PLUGIN_UPDATES_CHECK PLUGIN_UPDATES_INTERVAL

gitq() { git -c user.email=t@example.invalid -c user.name=t "$@"; }
# repo <dir>: a work tree with a remote bare repo at <dir>.git beside it (the "GitHub" copy).
newrepo() { mkdir -p "$1"; gitq -C "$1" init -q -b main; }
commit() { gitq -C "$1" add -A; gitq -C "$1" commit -qm "$2"; git -C "$1" rev-parse HEAD; }
catalog() { # <dir> <json plugins array>
  mkdir -p "$1/.claude-plugin"
  printf '{"name":"%s","owner":{"name":"t"},"plugins":%s}\n' "$(basename "$1")" "$2" > "$1/.claude-plugin/marketplace.json"; }
manifest() { mkdir -p "$1/.claude-plugin"; if [ -n "${3:-}" ]; then printf '{"name":"%s","version":"%s"}\n' "$2" "$3"; else printf '{"name":"%s"}\n' "$2"; fi > "$1/.claude-plugin/plugin.json"; }
publish() { git -C "$1" push -q "$GH/$(basename "$1").git" HEAD:main --tags 2>/dev/null || { git init -q --bare -b main "$GH/$(basename "$1").git"; git -C "$1" push -q "$GH/$(basename "$1").git" HEAD:main --tags; }; }

# Marketplace "mk" (GitHub source): versioned plugin "ver", unversioned plugins "unv" and "other".
M="$T/src/mk"; newrepo "$M"
manifest "$M/plugins/ver" ver 1.0.0; manifest "$M/plugins/unv" unv; manifest "$M/plugins/other" other
catalog "$M" '[{"name":"ver","source":"./plugins/ver"},{"name":"unv","source":"./plugins/unv"},{"name":"other","source":"./plugins/other"},{"name":"gone","source":"./plugins/other"}]'
S0="$(commit "$M" seed)"; publish "$M"
# Marketplace "eng" (GitHub source) pinning an external repo by tag, like wiki-engine.
catalog "$T/src/eng" '[{"name":"eng","version":"2.0.0","source":{"source":"github","repo":"x/eng","ref":"v2.0.0"}}]'
gitq -C "$T/src/eng" init -q -b main; commit "$T/src/eng" seed >/dev/null; publish "$T/src/eng"
# Marketplace "ext" (GitHub source) whose entry points at ANOTHER repo with no ref and no
# version in the catalog — credential-guard's shape. The version lives in that repo's plugin.json.
X="$T/src/cg"; newrepo "$X"; manifest "$X" cg 0.4.0; CG0="$(commit "$X" seed)"; publish "$X"
XU="$T/src/unv-ext"; newrepo "$XU"; manifest "$XU" uext; UX0="$(commit "$XU" seed)"; publish "$XU"
catalog "$T/src/ext" '[{"name":"cg","source":{"source":"github","repo":"x/cg"}},{"name":"uext","source":{"source":"github","repo":"x/unv-ext"}}]'
gitq -C "$T/src/ext" init -q -b main; commit "$T/src/ext" seed >/dev/null; publish "$T/src/ext"

# Marketplace "dir" (directory source): a local clone with its own upstream.
D="$T/src/dir"; newrepo "$D"; manifest "$D/plugins/dp" dp
catalog "$D" '[{"name":"dp","source":"./plugins/dp"}]'
D0="$(commit "$D" seed)"; git init -q --bare -b main "$T/dir-up.git"; git -C "$D" remote add origin "$T/dir-up.git"; git -C "$D" push -q -u origin main

now_iso() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))'; }
known() { cat > "$G/plugins/known_marketplaces.json" <<J
{"mk":{"source":{"source":"github","repo":"t/mk"},"installLocation":"$T/inst/mk"},
 "eng":{"source":{"source":"github","repo":"t/eng"},"installLocation":"$T/inst/eng"},
 "ext":{"source":{"source":"github","repo":"t/ext"},"installLocation":"$T/inst/ext"},
 "dir":{"source":{"source":"directory","path":"$D"},"installLocation":"$D"}}
J
}
# installed <ver-version> <unv-sha> <eng-version> <dp-sha> [lastUpdated]
installed() { local lu="${5:-2020-01-01T00:00:00.000Z}"; cat > "$G/plugins/installed_plugins.json" <<J
{"version":2,"plugins":{
 "ver@mk":[{"scope":"user","version":"$1","gitCommitSha":"$S0","lastUpdated":"$lu"}],
 "unv@mk":[{"scope":"user","version":"${2:0:12}","gitCommitSha":"$2","lastUpdated":"$lu"}],
$( [ "${GONE:-1}" = 1 ] && printf ' "gone@mk":[{"scope":"user","version":"%s","gitCommitSha":"%s","lastUpdated":"%s"}],' "${S0:0:12}" "$S0" "$lu" )
 "eng@eng":[{"scope":"user","version":"$3","lastUpdated":"$lu"}],
 "cg@ext":[{"scope":"user","version":"${CG:-0.4.0}","lastUpdated":"$lu"}],
 "uext@ext":[{"scope":"user","version":"${UX:-${UX0:0:12}}","gitCommitSha":"${UXS:-$UX0}","lastUpdated":"$lu"}],
 "dp@dir":[{"scope":"user","version":"${4:0:12}","gitCommitSha":"$4","lastUpdated":"$lu"}]}}
J
}
run() { python3 "$CHECK" --hook "$@" < /dev/null 2>"$T/err"; }
msg() { python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t) if t.strip() else {}; print(d.get("systemMessage","")); print("---"); print(d.get("hookSpecificOutput",{}).get("additionalContext",""))'; }
known

# 1 — CONTROL. Everything at the latest release: one line says so, nothing is offered.
installed 1.0.0 "$S0" 2.0.0 "$D0"
# "gone" is in the catalog at seed; drop it later.
out="$(run | msg)"
if printf '%s' "$out" | grep -q 'plugins: 7 current'; then ck 0 "all current: one line says how many were checked"; else ck 1 "all current: $out"; fi
if ! printf '%s' "$out" | grep -q 'claude plugin update'; then ck 0 "all current: nothing offered"; else ck 1 "offered an update with nothing to update: $out"; fi
[ ! -e "$T/CLAUDE-RAN" ]; ck $? "the check never runs claude"

# 2 — upstream moves: ver bumps its version, unv changes, other changes, gone is dropped, eng tags 2.1.0.
manifest "$M/plugins/ver" ver 1.1.0; echo x > "$M/plugins/unv/f"
catalog "$M" '[{"name":"ver","source":"./plugins/ver"},{"name":"unv","source":"./plugins/unv"},{"name":"other","source":"./plugins/other"}]'
S1="$(commit "$M" bump)"; publish "$M"
catalog "$T/src/eng" '[{"name":"eng","version":"2.1.0","source":{"source":"github","repo":"x/eng","ref":"v2.1.0"}}]'
commit "$T/src/eng" bump >/dev/null; publish "$T/src/eng"
# Fresh cache from case 1: the interval has not passed, so nothing new is seen yet (rate limit).
out="$(run | msg)"
if printf '%s' "$out" | grep -q 'plugins: 7 current'; then ck 0 "inside the interval the cached lookup answers"; else ck 1 "re-fetched inside the interval: $out"; fi
out="$(PLUGIN_UPDATES_INTERVAL=0 run | msg)"
if printf '%s' "$out" | grep -q 'ver@mk 1.0.0 → 1.1.0'; then ck 0 "a versioned plugin names old → new"; else ck 1 "versioned bump missed: $out"; fi
if printf '%s' "$out" | grep -q "unv@mk ${S0:0:12} → ${S1:0:12}"; then ck 0 "an unversioned plugin whose files changed is named"; else ck 1 "unversioned change missed: $out"; fi
if printf '%s' "$out" | grep -q 'eng@eng 2.0.0 → 2.1.0'; then ck 0 "a tag-pinned external plugin is named"; else ck 1 "tag bump missed: $out"; fi
if printf '%s' "$out" | grep -q 'gone@mk.*no longer in'; then ck 0 "a plugin dropped from its marketplace is reported"; else ck 1 "dropped plugin missed: $out"; fi
if ! printf '%s' "$out" | grep -q 'dp@dir'; then ck 0 "CONTROL: an unchanged directory plugin is not named"; else ck 1 "dp named while current: $out"; fi
if printf '%s' "$out" | grep -q 'claude plugin update ver@mk' && printf '%s' "$out" | grep -q 'claude plugin update eng@eng'; then ck 0 "each outdated plugin carries its update command"; else ck 1 "commands missing: $out"; fi
if printf '%s' "$out" | grep -qi 'reload-plugins'; then ck 0 "the offer says how to load the update"; else ck 1 "no reload instruction: $out"; fi
if ! printf '%s' "$out" | grep -q 'claude plugin update other@mk'; then ck 0 "CONTROL: a plugin not installed is not offered"; else ck 1 "offered an uninstalled plugin"; fi

# 2b — an EXTERNAL plugin repo named with no ref and no catalog version: its own plugin.json
# carries the version, so the check reads it there rather than reporting "not checked".
# Found live on the work machine: credential-guard@pleejr, whose catalog entry is repo-only.
manifest "$X" cg 0.5.0; commit "$X" bump >/dev/null; publish "$X"
echo e > "$XU/f"; UX1="$(commit "$XU" bump)"; publish "$XU"
out="$(PLUGIN_UPDATES_INTERVAL=0 run | msg)"
if printf '%s' "$out" | grep -q 'cg@ext 0.4.0 → 0.5.0'; then ck 0 "an external plugin repo is compared by its own plugin.json version"; else ck 1 "external version missed: $out"; fi
if printf '%s' "$out" | grep -q "uext@ext ${UX0:0:12} → ${UX1:0:12}"; then ck 0 "an unversioned external plugin repo is compared by its commit"; else ck 1 "external commit missed: $out"; fi
if ! printf '%s' "$out" | grep -q 'not checked'; then ck 0 "no plugin is left unchecked for want of a catalog version"; else ck 1 "still unchecked: $out"; fi
# CONTROL: the external lookup obeys the interval like every other one.
manifest "$X" cg 0.6.0; commit "$X" bump2 >/dev/null; publish "$X"
out="$(run | msg)"
if ! printf '%s' "$out" | grep -q '0.6.0'; then ck 0 "an external lookup is rate-limited too"; else ck 1 "external repo re-fetched inside the interval: $out"; fi
CG=0.6.0; UX="${UX1:0:12}"; UXS="$UX1"

# 3 — an unversioned plugin is NOT outdated by a commit that only touches another plugin.
GONE=0; installed 1.1.0 "$S1" 2.1.0 "$D0"
echo y > "$M/plugins/other/g"; S2="$(commit "$M" other-only)"; publish "$M"
out="$(PLUGIN_UPDATES_INTERVAL=0 run | msg)"
if ! printf '%s' "$out" | grep -q 'unv@mk'; then ck 0 "a commit elsewhere in the marketplace does not flag an unversioned plugin"; else ck 1 "flagged on an unrelated commit: $out"; fi

# 4 — SELF-CLEARING and OFFLINE. Remotes gone; installed moves to latest; answered from the cache.
mv "$GH" "$GH.off"
out="$(run | msg)"
if printf '%s' "$out" | grep -q 'plugins: 6 current'; then ck 0 "updating clears the report with no network"; else ck 1 "stale after update: $out"; fi
mv "$GH.off" "$GH"

# 5 — REFETCH ON MOVE. A plugin updated after the lookup means the cache predates a release;
# look again inside the interval.
catalog "$T/src/eng" '[{"name":"eng","version":"2.2.0","source":{"source":"github","repo":"x/eng","ref":"v2.2.0"}}]'
commit "$T/src/eng" bump2 >/dev/null; publish "$T/src/eng"
sleep 1; installed 1.1.0 "$S1" 2.1.0 "$D0" "$(now_iso)"
out="$(run | msg)"
if printf '%s' "$out" | grep -q 'eng@eng 2.1.0 → 2.2.0'; then ck 0 "a plugin updated since the lookup triggers a new lookup"; else ck 1 "stale cache hid a release: $out"; fi

# 6 — DIRECTORY marketplace: a commit in the clone flags its plugin; an upstream ahead of the
# clone is reported with the pull it needs.
installed 1.1.0 "$S1" 2.2.0 "$D0"
echo z > "$D/plugins/dp/h"; commit "$D" local >/dev/null
out="$(run | msg)"
if printf '%s' "$out" | grep -q "dp@dir ${D0:0:12} →"; then ck 0 "a directory plugin behind its clone is named"; else ck 1 "directory change missed: $out"; fi
W="$T/other-clone"; git clone -q "$T/dir-up.git" "$W"; echo w > "$W/w"; commit "$W" upstream >/dev/null; git -C "$W" push -q origin main
out="$(PLUGIN_UPDATES_INTERVAL=0 run | msg)"
if printf '%s' "$out" | grep -q "git -C $D pull --ff-only"; then ck 0 "a clone behind its upstream is reported with the pull"; else ck 1 "upstream lag missed: $out"; fi

# 7 — a marketplace that cannot be reached on first lookup is "not checked", never "current".
rm -rf "$DATA"; mkdir -p "$DATA"; mv "$GH" "$GH.off"
out="$(PLUGIN_UPDATES_INTERVAL=0 run | msg)"
if printf '%s' "$out" | grep -q 'not checked.*mk' && ! printf '%s' "$out" | grep -q 'plugins: [0-9]* current$'; then ck 0 "an unreachable marketplace is reported as not checked"; else ck 1 "unreachable read as current: $out"; fi
mv "$GH.off" "$GH"

# 7b — the reason survives the interval: the next session, still unreachable and inside the
# interval, repeats why rather than claiming no lookup ever ran. Found live: pleejr-ww
# read "never looked up" three hours after a lookup that failed.
mv "$GH" "$GH.off"
out="$(run | msg)"
if printf '%s' "$out" | grep -q 'mk (lookup failed)'; then ck 0 "a failed lookup's reason is kept inside the interval"; else ck 1 "reason lost inside the interval: $out"; fi
mv "$GH.off" "$GH"

# 7c — a marketplace whose SOURCE changed is looked up at once, not after the interval.
# machine-config restores a directory marketplace as its GitHub remote; the directory
# lookup's stamp then held the new source's first fetch off for a day.
publish "$D"
PLUGIN_UPDATES_INTERVAL=0 run >/dev/null
sed -i.bak 's|"dir":{"source":{"source":"directory","path":"[^"]*"}|"dir":{"source":{"source":"github","repo":"t/dir"}|' "$G/plugins/known_marketplaces.json"; rm -f "$G/plugins/known_marketplaces.json.bak"
grep -q '"repo":"t/dir"' "$G/plugins/known_marketplaces.json" || { echo "  FAIL fixture: dir was not switched to github"; fail=1; }
out="$(run | msg)"
if ! printf '%s' "$out" | grep -q 'not checked.*dir'; then ck 0 "a marketplace whose source changed is looked up at once"; else ck 1 "re-sourced marketplace waited out the interval: $out"; fi
# CONTROL: the same source inside the interval is still rate-limited — no lookup, same answer.
git -C "$DATA/mirrors/dir.git" update-ref -d refs/pu/latest 2>/dev/null
out="$(run | msg)"
if printf '%s' "$out" | grep -q 'not checked.*dir'; then ck 0 "CONTROL: an unchanged source is not re-fetched inside the interval"; else ck 1 "fetched again inside the interval: $out"; fi

# 8 — opt-out is silent and does no lookup; corrupt input never breaks the session.
out="$(PLUGIN_UPDATES_CHECK=0 run)"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then ck 0 "PLUGIN_UPDATES_CHECK=0 is silent"; else ck 1 "opt-out spoke: $out"; fi
echo '{nope' > "$G/plugins/installed_plugins.json"
out="$(run)"; rc=$?
if [ "$rc" -eq 0 ]; then ck 0 "corrupt installed_plugins.json exits 0"; else ck 1 "corrupt input exit $rc"; fi
[ ! -e "$T/CLAUDE-RAN" ]; ck $? "the check never ran claude in any case"
exit "$fail"
