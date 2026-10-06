#!/usr/bin/env bash
# Fixture pass for check-skill-name.py. Run from anywhere: scripts/test-check.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; CHK="$HERE/check-skill-name.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
skill() { mkdir -p "$T/skills/$1"; printf -- '---\nname: %s\ndescription: x\n---\nbody\n' "$1" > "$T/skills/$1/SKILL.md"; }
payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "${2:-Write}" "$1"; }
run() { python3 -I "$CHK" < <(payload "$@"); }

skill frobnicate-things; skill review-plan; skill statusline; skill reviewplan
out="$(run "$T/skills/frobnicate-things/SKILL.md")"
case "$out" in *additionalContext*frobnicate-things*) ok "a non-verb name is flagged, naming it";; *) bad "non-verb name not flagged: [$out]";; esac
out="$(run "$T/skills/review-plan/SKILL.md" Edit)"; [ -z "$out" ] && ok "a verb-led name is silent (Edit payload)" || bad "verb-led flagged: $out"
out="$(run "$T/skills/statusline/SKILL.md")"; [ -z "$out" ] && ok "an exempt name is silent" || bad "exempt flagged: $out"
out="$(run "$T/skills/reviewplan/SKILL.md")"; [ -n "$out" ] && ok "a verb glued to its object is not a verb-led name" || bad "'reviewplan' passed"
mkdir -p "$T/docs"; printf -- '---\nname: frobnicate\n---\n' > "$T/docs/SKILL.md"
out="$(run "$T/docs/SKILL.md")"; [ -z "$out" ] && ok "a SKILL.md outside a skills/ directory is ignored" || bad "non-skills path flagged"
out="$(run "$T/skills/frobnicate-things/NOTES.md")"; [ -z "$out" ] && ok "another file in a skill directory is ignored" || bad "NOTES.md flagged"
out="$(echo 'not json' | python3 -I "$CHK")"; rc=$?; [ -z "$out" ] && [ "$rc" = 0 ] && ok "garbage input exits 0 silently" || bad "garbage: rc=$rc [$out]"
out="$(run "$T/skills/gone/SKILL.md")"; rc=$?; [ -z "$out" ] && [ "$rc" = 0 ] && ok "an unreadable file exits 0 silently" || bad "missing file: rc=$rc"

# Negative control: the verb list drives the verdict. Without 'review' on it, review-plan must warn.
mkdir -p "$T/data2"; grep -v '^review$' "$HERE/../data/verbs.txt" > "$T/data2/verbs.txt"; cp "$HERE/../data/exempt.txt" "$T/data2/"
out="$(SKILL_NAME_GUARD_DATA="$T/data2" run "$T/skills/review-plan/SKILL.md")"
[ -n "$out" ] && ok "dropping a verb from the list makes its skills warn (the list is what decides)" || bad "list ignored"

# Every skill that exists today passes, so the rule can be enforced without a rename.
n=0; for f in "$HERE"/../../*/skills/*/SKILL.md "${SKILL_NAME_GUARD_EXTRA:-/nonexistent}"/*/SKILL.md; do
  [ -f "$f" ] || continue; nm="$(sed -n 's/^name: *//p' "$f" | head -1)"; n=$((n+1))
  python3 -I "$CHK" --name "$nm" >/dev/null || bad "existing skill '$nm' fails the rule"
done; [ "$n" -gt 0 ] && ok "all $n existing skill names pass" || bad "found no skills to check"
[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
