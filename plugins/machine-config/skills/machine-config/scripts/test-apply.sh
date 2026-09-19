#!/usr/bin/env bash
# test-apply.sh — fixture pass over apply.sh's guards. This repo runs no CI, so this script
# IS the gate: without it the guards below are prose. It touches nothing real — a throwaway
# CLAUDE_CONFIG_DIR and a throwaway config repo, both under mktemp, removed at the end.
#
# Every assertion here was proven able to fail by mutating the SUBJECT, never the assertion:
# dropping the home-path guard, the credential guard, the never-clobber rule, the orphan
# report, the --check read-only rule, the pre-overwrite backup, the identical-bytes adoption,
# the non-zero exit on refusal, and the dotfile skip each redden exactly the lines naming them.
# $SUBJECT re-points at a mutated copy, which is how that pass is run.
#
# Usage: scripts/test-apply.sh          (exit 0 = every guard held)
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${SUBJECT:-$here/apply.sh}"
T="$(mktemp -d)"; export CLAUDE_CONFIG_DIR="$T/cfg"
export MACHINE_CONFIG_REPO="$T/repo"
mkdir -p "$CLAUDE_CONFIG_DIR" "$MACHINE_CONFIG_REPO/shared/output-styles"
printf '{"model":"opus","theme":"dark"}\n' > "$MACHINE_CONFIG_REPO/shared/settings.shared.json"
printf '{"model":"opus","theme":"dark"}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
# The SKILLS store is the second source of shared styles, and it is derived from the script's
# own location — so without this override the fixtures would read whatever the operator's real
# skills repo happens to carry, and pass or fail on state no one in this file wrote.
export MC_SKILLS_REPO="$T/skillsrepo"
mkdir -p "$MC_SKILLS_REPO"
SK="$MC_SKILLS_REPO/plugins/craft/output-styles"
fail=0
ck() { if [ "$1" = 0 ]; then printf '  ok   %s\n' "$2"; else printf '  FAIL %s\n' "$2"; fail=1; fi; }
style() { printf -- '---\nname: %s\n---\n\n%s\n' "$1" "$2" > "$MACHINE_CONFIG_REPO/shared/output-styles/$1.md"; }
skstyle() { mkdir -p "$SK"; printf -- '---\nname: %s\n---\n\n%s\n' "$1" "$2" > "$SK/$1.md"; }
run() { out="$("$S" "$@" 2>&1)"; rc=$?; }

MAN="$CLAUDE_CONFIG_DIR/.machine-config-shared-styles"
DST="$CLAUDE_CONFIG_DIR/output-styles"

# --- 1. a clean shared style installs, and is recorded -----------------------------------
style Briefing "Report work as a short briefing, not a narrative."
run
[ "$rc" -eq 0 ]; ck $? "clean style: exits 0"
[ -f "$DST/Briefing.md" ]; ck $? "clean style: installed into the config dir"
cmp -s "$DST/Briefing.md" "$MACHINE_CONFIG_REPO/shared/output-styles/Briefing.md"; ck $? "clean style: byte-identical to shared"
grep -q ' Briefing.md$' "$MAN"; ck $? "clean style: recorded in the manifest"

# --- 2. a second run is a no-op, and --check agrees --------------------------------------
run
printf '%s' "$out" | grep -q 'not installed here'; [ $? -ne 0 ]; ck $? "idempotent: second run reinstalls nothing"
run --check
[ "$rc" -eq 0 ]; ck $? "--check: exits 0 when in sync"

# --- 3. a shared UPDATE lands, because this machine installed the copy that is here -------
style Briefing "Report work as a short briefing. Numbered bullets, expandable."
run --check
[ "$rc" -eq 1 ]; ck $? "shared update: --check exits 1"
printf '%s' "$out" | grep -q 'shared copy updated'; ck $? "shared update: --check names it"
grep -q 'Numbered bullets' "$DST/Briefing.md"; [ $? -ne 0 ]; ck $? "shared update: --check did NOT write"
run
grep -q 'Numbered bullets' "$DST/Briefing.md"; ck $? "shared update: applied"
ls "$DST"/Briefing.md.bak.* >/dev/null 2>&1; ck $? "shared update: backed the previous copy up"

# --- 4. a LOCAL edit is never overwritten ------------------------------------------------
printf -- '---\nname: Briefing\n---\n\nMy own wording, hand written.\n' > "$DST/Briefing.md"
run
[ "$rc" -eq 3 ]; ck $? "local edit: exits 3 (refused something)"
printf '%s' "$out" | grep -q 'REFUSING output style'; ck $? "local edit: says it refused"
grep -q 'My own wording' "$DST/Briefing.md"; ck $? "local edit: the operator's prose survives"

# --- 5. --force overwrites, but backs up first -------------------------------------------
run --force
[ "$rc" -eq 0 ]; ck $? "--force: exits 0"
grep -q 'Numbered bullets' "$DST/Briefing.md"; ck $? "--force: shared copy took"
grep -rq 'My own wording' "$DST"/Briefing.md.bak.* 2>/dev/null; ck $? "--force: the overwritten prose is recoverable"

# --- 6. guard — a home path makes a style machine-local ----------------------------------
style Pathy "Read the vault at /Users/someone/vault before answering."
run
[ "$rc" -eq 3 ]; ck $? "home path: exits 3"
printf '%s' "$out" | grep -q "REFUSING output style 'Pathy.md'"; ck $? "home path: refused by name"
printf '%s' "$out" | grep -q 'machine-local'; ck $? "home path: says why"
[ ! -e "$DST/Pathy.md" ]; ck $? "home path: nothing was installed"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Pathy.md"

# --- 7. guard — credential-shaped content ------------------------------------------------
style Leaky 'Use token ghp_0123456789abcdefghij0123456789abcdefgh when asked.'
run
[ "$rc" -eq 3 ]; ck $? "credential: exits 3"
printf '%s' "$out" | grep -q 'credential-shaped'; ck $? "credential: named as such"
[ ! -e "$DST/Leaky.md" ]; ck $? "credential: nothing was installed"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Leaky.md"

# --- 8. a style already present by another route (restore) is adopted, not refused --------
# The adopt branch used to be SILENT, which is the one outcome an operator cannot act on:
# on a machine already running the style, --check said nothing about styles at all, so
# "managed" and "not even seen by this script" looked identical — and the real run then
# wrote a manifest the dry run had not predicted.
style Restored "Prose that arrived with a restore."
cp "$MACHINE_CONFIG_REPO/shared/output-styles/Restored.md" "$DST/Restored.md"
run --check
[ "$rc" -eq 0 ]; ck $? "adopt: --check does not call an identical file drift"
printf '%s' "$out" | grep -q "already here and identical"; ck $? "adopt: --check SAYS the file is present and would be recorded"
[ ! -f "$MAN" ] || ! grep -q ' Restored.md$' "$MAN"; ck $? "adopt: --check still wrote nothing"
run
[ "$rc" -eq 0 ]; ck $? "restored copy: identical bytes are adopted, not refused"
printf '%s' "$out" | grep -q "adopted as managed"; ck $? "adopt: the real run says it recorded the file"
grep -q ' Restored.md$' "$MAN"; ck $? "restored copy: recorded, so the NEXT shared update is not read as an edit"
run
printf '%s' "$out" | grep -q "adopted as managed"; [ $? -ne 0 ]; ck $? "adopt: steady state is quiet — it reports the transition, not every run"
style Restored "Prose that arrived with a restore, then moved on."
run
[ "$rc" -eq 0 ]; ck $? "restored copy: the following shared update applies cleanly"
grep -q 'then moved on' "$DST/Restored.md"; ck $? "restored copy: update took"

# --- 9. a style dropped from shared/ is reported, never deleted ---------------------------
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Restored.md"
run
printf '%s' "$out" | grep -q "'Restored.md' is no longer in any shared store"; ck $? "orphan: reported"
[ -f "$DST/Restored.md" ]; ck $? "orphan: NOT deleted"

# --- 10. dotfiles are skipped, as everywhere else in this skill ---------------------------
printf -- '---\nname: x\n---\nsecret scratch\n' > "$MACHINE_CONFIG_REPO/shared/output-styles/.scratch.md"
run
[ ! -e "$DST/.scratch.md" ]; ck $? "dotfile: skipped"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/.scratch.md"

# --- 11. the settings half still works, and its denylist still refuses --------------------
printf '{"model":"opus","theme":"light"}\n' > "$MACHINE_CONFIG_REPO/shared/settings.shared.json"
run
[ "$(jq -r .theme "$CLAUDE_CONFIG_DIR/settings.json")" = "light" ]; ck $? "settings: shared value still merges"
printf '{"model":"opus","hooks":{"X":1}}\n' > "$MACHINE_CONFIG_REPO/shared/settings.shared.json"
run
printf '%s' "$out" | grep -q "REFUSING 'hooks'"; ck $? "settings: denylist still refuses"
[ "$rc" -eq 3 ]; ck $? "settings: a denied key now reports a non-zero status too"
[ "$(jq -r '.hooks // "absent"' "$CLAUDE_CONFIG_DIR/settings.json")" = "absent" ]; ck $? "settings: the denied key never landed"

# --- 12. --check and --force together is a contradiction, not a silent winner -------------
run --check --force
[ "$rc" -eq 2 ]; ck $? "flags: --check with --force exits 2"
run --promote X --check
[ "$rc" -eq 2 ]; ck $? "flags: --promote is its own mode, not a modifier"

# --- 13. --check must predict the REAL run's status, refusal included --------------------
# A shared style naming a home path changes nothing here, so `drift` stays 0 — and --check
# used to exit 0 while the real run exited 3. A dry run that disagrees with the real run is
# the same defect class this file already fixed once in the adopt branch.
printf '{"model":"opus","theme":"dark"}\n' > "$MACHINE_CONFIG_REPO/shared/settings.shared.json"
run   # settle any pending drift first, so the next assertions isolate the refusal
style Pathy2 "Read /Users/someone/vault before answering."
run --check
[ "$rc" -eq 3 ]; ck $? "--check: a guard refusal exits 3, the same as the real run"
run
[ "$rc" -eq 3 ]; ck $? "--check agreed with the real run"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Pathy2.md"

# --- 14. --promote: the publish half ------------------------------------------------------
# Without it there is no publish path at all: a style is edited where it is USED, autosave
# snapshots it to machines/<host>/ (the restore half), and shared/ never learns.
printf -- '---\nname: Local\n---\n\nWritten on this machine.\n' > "$DST/Local.md"
run --promote Local --to config
[ "$rc" -eq 0 ]; ck $? "promote: exits 0"
[ -f "$MACHINE_CONFIG_REPO/shared/output-styles/Local.md" ]; ck $? "promote: the file reached shared/"
cmp -s "$DST/Local.md" "$MACHINE_CONFIG_REPO/shared/output-styles/Local.md"; ck $? "promote: byte-identical"
printf '%s' "$out" | grep -q 'NOT committed'; ck $? "promote: says it did not commit — committing is what publishes"
printf '%s' "$out" | grep -q 'git -C .* push'; ck $? "promote: prints the commands that would publish it"
run --check
[ "$rc" -eq 0 ]; ck $? "promote: apply now considers the style in sync"
run --promote Local --to config
printf '%s' "$out" | grep -q 'nothing to promote'; ck $? "promote: a second promote is a no-op, and says so"

# a promoted style must pass the SAME guards — this is the direction in which a home path
# would enter the shared store and be handed to every other machine
printf -- '---\nname: Leaks\n---\n\nOpen /Users/me/scratch first.\n' > "$DST/Leaks.md"
run --promote Leaks --to config
[ "$rc" -eq 3 ]; ck $? "promote: a home path is refused on the way OUT too"
[ ! -e "$MACHINE_CONFIG_REPO/shared/output-styles/Leaks.md" ]; ck $? "promote: the refused style never reached shared/"
# assert the PROPERTY (it points at where), not the coordinate — an earlier version of this
# line hardcoded `line 4` and failed on a fixture with one more blank line
printf '%s' "$out" | grep -qE 'line [0-9]+:.*/Users/me/scratch'; ck $? "promote: names the offending line so it can be fixed"
printf -- '---\nname: Tok\n---\n\nuse ghp_0123456789abcdefghij0123456789abcdefgh\n' > "$DST/Tok.md"
run --promote Tok --to config
[ "$rc" -eq 3 ]; ck $? "promote: credential-shaped content is refused on the way out"
[ ! -e "$MACHINE_CONFIG_REPO/shared/output-styles/Tok.md" ]; ck $? "promote: the credential never reached shared/"
run --promote Nonexistent
[ "$rc" -eq 2 ]; ck $? "promote: an unknown style is a usage error, not a silent no-op"
printf '%s' "$out" | grep -q 'styles on this machine'; ck $? "promote: lists what IS here"

# --- 15. the session-start drop-in surfaces shared drift, in both directions --------------
# The warning is the other half of --promote: without it, "shared" means "shared if someone
# remembers a command", and the forgetting is silent. Snapshot drift and shared drift are
# independent signals, so they must ACCUMULATE rather than short-circuit each other.
export MACHINE_CONFIG_HOST=fixturehost
mkdir -p "$MACHINE_CONFIG_REPO/machines/fixturehost"

# Clear section 14's refusal fixtures out of the config dir first. Leaving the fake token
# there makes backup.sh refuse rather than report drift, so the two-signal assertion below
# would measure "backup BLOCKED" while claiming to measure staleness — a fixture that fails
# for a reason unrelated to what it tests. Asserted rather than only cleaned up, because the
# interaction is real and was found by tripping over it:
"$here/backup.sh" --check >/dev/null 2>&1
[ $? -ge 2 ]; ck $? "session-check: a credential left in the config dir makes backup REFUSE, not report drift"
rm -f "$DST/Tok.md" "$DST/Leaks.md"
SC="$here/session-check.sh"
sc() { scout="$(bash "$SC" 2>&1)"; scrc=$?; }

# in sync -> the drop-in says nothing at all, which is what keeps a banner readable
"$S" >/dev/null 2>&1
"$here/backup.sh" >/dev/null 2>&1
sc
[ "$scrc" -eq 0 ]; ck $? "session-check: always exits 0, whatever it finds"

# Styles moved OUT of this drop-in and into session-apply.sh, which installs them instead of
# reporting them. This assertion is the one that catches a revert: if the styles half comes
# back here it will also be applied by the sibling, and the banner grows a line describing
# work already done, from a read taken before the store was even synced.
SA="$here/session-apply.sh"
sa() { saout="$(bash "$SA" 2>&1)"; sarc=$?; }
style Unapplied "Prose no machine has taken yet."
rm -f "$DST/Unapplied.md"
sc
printf '%s' "$scout" | grep -q 'Unapplied'; rc_inv=$?
[ "$rc_inv" -ne 0 ]; ck $? "session-check: no longer reports styles — that is session-apply's half"

# session-apply INSTALLS it, rather than telling someone to. The file landing is the point;
# everything else here is how the banner describes it.
sa
[ "$sarc" -eq 0 ]; ck $? "session-apply: always exits 0, whatever it finds"
[ -f "$DST/Unapplied.md" ]; ck $? "session-apply: installed the style with no human in the loop"
printf '%s' "$saout" | grep -q 'Unapplied.md'; ck $? "session-apply: names what it installed"
sa
[ -z "$saout" ]; ck $? "session-apply: silent once in sync, which is what keeps a banner readable"

# THE RESTART CASE. The session read its style file before this hook ran, so a change to the
# ACTIVE style leaves the session following prose that is no longer on disk. Nothing else in
# the banner tells the user that, and by the time they notice they have worked under it.
printf '{"outputStyle":"Unapplied"}\n' > "$CLAUDE_CONFIG_DIR/settings.json.styletest"
( export CLAUDE_PROJECT_DIR="$T/proj"
  mkdir -p "$T/proj/.claude"
  printf '{"outputStyle":"Unapplied"}\n' > "$T/proj/.claude/settings.local.json"
  style Unapplied "Prose no machine has taken yet, REVISED."
  saout2="$(bash "$SA" 2>&1)"
  printf '%s' "$saout2" | sed -n 1p | grep -q 'RESTART' \
    && printf '%s' "$saout2" | grep -q 'RUNNING' )
ck $? "session-apply: a change to the style the session is RUNNING asks for a restart"
grep -q 'REVISED' "$DST/Unapplied.md"; ck $? "session-apply: ...and still installed it"
( export CLAUDE_PROJECT_DIR="$T/proj"
  style Other "A style nobody selected."
  rm -f "$DST/Other.md"
  saout3="$(bash "$SA" 2>&1)"
  printf '%s' "$saout3" | grep -q 'RESTART' )
[ $? -ne 0 ]; ck $? "session-apply: a style the session is NOT running does not cry restart"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Other.md" "$DST/Other.md" "$CLAUDE_CONFIG_DIR/settings.json.styletest"
rm -rf "$T/proj"

# a LOCAL edit -> apply refuses, and the note must offer BOTH exits without choosing
printf -- '---\nname: Unapplied\n---\nmy own later wording\n' > "$DST/Unapplied.md"
sa
printf '%s' "$saout" | grep -q 'styles: REFUSED'; ck $? "session-apply: a refusal reads louder than an ordinary install"
printf '%s' "$saout" | grep -q '\-\-promote'; ck $? "session-apply: offers publishing the local copy"
printf '%s' "$saout" | grep -q '\-\-force'; ck $? "session-apply: offers taking the shared copy"
printf '%s' "$saout" | grep -q 'Do not pick for the user'; ck $? "session-apply: refuses to choose between them"

# session-check keeps its own half, and still reports it
printf '{"drifted":true}\n' > "$CLAUDE_CONFIG_DIR/keybindings.json"
sc
printf '%s' "$scout" | sed -n 1p | grep -q 'snapshot stale'; ck $? "session-check: still reports snapshot drift"

# --- reset — section 15 deliberately leaves a REFUSED style behind, and every assertion
# below reads the exit status, so its refusal would be attributed to the second store.
rm -f "$DST/Unapplied.md" "$MACHINE_CONFIG_REPO/shared/output-styles/Unapplied.md"
"$S" >/dev/null 2>&1
run
[ "$rc" -eq 0 ]; ck $? "reset: the fixture is back to a clean apply before the store tests"

# --- 16. the SKILLS store is a source too ------------------------------------------------
# The config repo is per boundary — work and personal are separate repos — so it structurally
# cannot carry a style from a work laptop to a personal one. This store can, which is the
# whole reason it exists.
skstyle Crossing "Prose that has to reach both laptops."
run --check
[ "$rc" -eq 1 ]; ck $? "skills store: --check sees a style it has not installed"
run
[ -f "$DST/Crossing.md" ]; ck $? "skills store: installed from the skills repo"
cmp -s "$DST/Crossing.md" "$SK/Crossing.md"; ck $? "skills store: byte-identical"
grep -q ' Crossing.md$' "$MAN"; ck $? "skills store: recorded in the same manifest"
skstyle Crossing "Prose that has to reach both laptops, revised."
run
grep -q 'revised' "$DST/Crossing.md"; ck $? "skills store: a later update applies like any other"

# --- 17. the same guards apply to the second store ----------------------------------------
# A store that crosses a boundary is the LAST place a home path or a credential should pass.
skstyle SkPathy "Open /Users/someone/notes first."
run
[ "$rc" -eq 3 ]; ck $? "skills store: a home path is refused here too"
[ ! -e "$DST/SkPathy.md" ]; ck $? "skills store: the refused style was not installed"
rm -f "$SK/SkPathy.md"

# --- 18. a name in BOTH stores is refused, never resolved ---------------------------------
# The two stores have different reach, so silently preferring either installs prose the
# operator believes lives somewhere else — and then tracks updates from the wrong copy.
style Both "The config repo copy."
skstyle Both "The skills repo copy."
run
[ "$rc" -eq 3 ]; ck $? "conflict: exits 3"
printf '%s' "$out" | grep -q "REFUSING output style 'Both.md'"; ck $? "conflict: refused by name"
printf '%s' "$out" | grep -q "more than one shared store"; ck $? "conflict: says why"
printf '%s' "$out" | grep -q "$MACHINE_CONFIG_REPO/shared/output-styles/Both.md"; ck $? "conflict: names the config-store path"
printf '%s' "$out" | grep -q "$SK/Both.md"; ck $? "conflict: names the skills-store path — a duplicate is not actionable without both"
[ ! -e "$DST/Both.md" ]; ck $? "conflict: NEITHER copy was installed"
run --check
[ "$rc" -eq 3 ]; ck $? "conflict: --check agrees with the real run"
rm -f "$SK/Both.md"
run
[ -f "$DST/Both.md" ]; ck $? "conflict: resolving it by deleting one copy lets the other install"
grep -q 'config repo copy' "$DST/Both.md"; ck $? "conflict: the surviving copy is the one that was kept"

# --- 19. an orphan must be gone from EVERY store, not just the one it came from -----------
# Reporting a style as dropped while another store still carries it would invite deleting a
# file that is still managed.
# Both directions, deliberately: a check that looks at only ONE store still passes the case
# where the surviving copy happens to be in the store it looks at. Only the other direction
# reddens it, which is why this walks the style through both.
skstyle Moving "Carried by the skills store."
run >/dev/null 2>&1
run
printf '%s' "$out" | grep -q "'Moving.md' is no longer"; [ $? -ne 0 ]; ck $? "orphan: carried ONLY by the skills store, so not reported as dropped"
rm -f "$SK/Moving.md"
style Moving "Carried by the config store."
run
printf '%s' "$out" | grep -q "'Moving.md' is no longer"; [ $? -ne 0 ]; ck $? "orphan: carried ONLY by the config store, so not reported as dropped"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Moving.md"
run
printf '%s' "$out" | grep -q "'Moving.md' is no longer in any shared store"; ck $? "orphan: gone from both stores, now reported"
[ -f "$DST/Moving.md" ]; ck $? "orphan: still not deleted"
rm -f "$DST/Moving.md"

# --- 20. --promote picks a store, and never invents a second copy of one name -------------
printf -- '---\nname: Fresh\n---\n\nBrand new prose.\n' > "$DST/Fresh.md"
run --promote Fresh
[ "$rc" -eq 0 ]; ck $? "promote: a new name exits 0"
[ -f "$SK/Fresh.md" ]; ck $? "promote: a NEW name defaults to the store that crosses the boundary"
[ ! -e "$MACHINE_CONFIG_REPO/shared/output-styles/Fresh.md" ]; ck $? "promote: ...and only there"
printf '%s' "$out" | grep -q 'BOTH boundaries'; ck $? "promote: warns that the mechanical guards cannot read the prose"
printf -- '---\nname: Fresh\n---\n\nBrand new prose, edited.\n' > "$DST/Fresh.md"
run --promote Fresh
[ -f "$SK/Fresh.md" ]; ck $? "promote: a known name goes back to the store it already lives in"
grep -q 'edited' "$SK/Fresh.md"; ck $? "promote: the update landed there"
[ ! -e "$MACHINE_CONFIG_REPO/shared/output-styles/Fresh.md" ]; ck $? "promote: the other store did not gain a second copy"
run --promote Fresh --to config
[ "$rc" -eq 0 ]; ck $? "promote: --to overrides the store it already lives in"
[ -f "$MACHINE_CONFIG_REPO/shared/output-styles/Fresh.md" ]; ck $? "promote: --to config wrote where it was told"
run --promote Fresh
[ "$rc" -eq 3 ]; ck $? "promote: a name now in BOTH stores is refused rather than guessed at"
printf '%s' "$out" | grep -q 'already in BOTH stores'; ck $? "promote: says which failure it is"
rm -f "$MACHINE_CONFIG_REPO/shared/output-styles/Fresh.md" "$SK/Fresh.md" "$DST/Fresh.md"
run --promote Local --to nowhere
[ "$rc" -eq 2 ]; ck $? "promote: an unknown --to value is a usage error"
run --to config
[ "$rc" -eq 2 ]; ck $? "promote: --to without --promote is a usage error, not a silent no-op"

# --- 21. the styles half works with NO config repo at all ---------------------------------
# A second laptop may want the shared prose and keep its own config elsewhere. Dying here
# would withhold the styles from exactly the machine the cross-boundary store exists to reach.
T2="$(mktemp -d)"
( export CLAUDE_CONFIG_DIR="$T2/cfg" MACHINE_CONFIG_REPO=""
  unset MACHINE_CONFIG_REPO
  mkdir -p "$CLAUDE_CONFIG_DIR"
  "$S" >/dev/null 2>&1 )
[ -f "$T2/cfg/output-styles/Crossing.md" ]; ck $? "no config repo: the skills store still installs"
# MC_SKILLS_REPO is pointed at a path that does not exist rather than UNSET: unset makes the
# locator derive the real skills repo from the script's own location, so this assertion would
# quietly stop testing "no store" the moment that repo gained an output-styles/ directory.
( export CLAUDE_CONFIG_DIR="$T2/cfg" MC_SKILLS_REPO="$T2/no-such-skills-repo"
  unset MACHINE_CONFIG_REPO
  out2="$("$S" 2>&1)"; rc2=$?
  [ "$rc2" -eq 2 ] && printf '%s' "$out2" | grep -q 'no config repo set' ) ; ck $? "no store at all: still the usage error it always was"
rm -rf "$T2"

# --- 22. the half-selectors -----------------------------------------------------------------
# session-apply.sh runs UNATTENDED at session start and takes --styles-only, so "does the
# narrow half stay narrow" is the assertion standing between an unattended hook and this
# machine's settings.json. Each was proven able to fail by dropping its guard in the subject.
run --styles-only --settings-only
[ "$rc" -eq 2 ]; ck $? "halves: asking for both exclusively is a usage error, not a silent pick"
run --promote Local --styles-only
[ "$rc" -eq 2 ]; ck $? "halves: --promote refuses to be combined with a half-selector"

# Drift BOTH halves at once, then take one half and assert the other did not move.
printf '{"model":"opus","theme":"dark","spinnerTipsEnabled":false}\n' > "$MACHINE_CONFIG_REPO/shared/settings.shared.json"
before="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
skstyle Halves 'Only the styles half should install this.'
run --styles-only
[ "$rc" -eq 0 ]; ck $? "styles-only: exits clean"
[ -f "$DST/Halves.md" ]; ck $? "styles-only: installed the style"
[ "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" = "$before" ]; ck $? "styles-only: left settings.json byte-identical despite pending drift"
printf '%s' "$out" | grep -q 'settings'; rc_inv=$?
[ "$rc_inv" -ne 0 ]; ck $? "styles-only: says nothing about the half it did not run"

skstyle Halves2 'Only the settings half runs, so this must NOT arrive.'
run --settings-only
[ "$rc" -eq 0 ]; ck $? "settings-only: exits clean"
grep -q 'spinnerTipsEnabled' "$CLAUDE_CONFIG_DIR/settings.json"; ck $? "settings-only: merged the shared key"
[ ! -e "$DST/Halves2.md" ]; ck $? "settings-only: installed no style"
rm -f "$SK/Halves.md" "$SK/Halves2.md" "$DST/Halves.md"

# --settings-only on a machine with no config repo must FAIL, not run to completion having
# done nothing and exit 0 — a caller that asked for settings and got silence.
T3="$(mktemp -d)"
( export CLAUDE_CONFIG_DIR="$T3/cfg"
  unset MACHINE_CONFIG_REPO
  mkdir -p "$CLAUDE_CONFIG_DIR"
  out3="$("$S" --settings-only 2>&1)"; rc3=$?
  [ "$rc3" -eq 2 ] && printf '%s' "$out3" | grep -q 'needs a config repo' ) ; ck $? "settings-only: no config repo is a loud failure, never a silent no-op"
rm -rf "$T3"


# --- 23. the craft plugin takes over the skills store -----------------------------------------
# With craft enabled Claude Code loads the skills store itself as `craft:<name>`, so apply.sh
# must stop copying it and remove the copies it made — but only those it can prove it made
# and nobody edited since. Each assertion was proven able to fail by mutating the subject.
skstyle Taken 'Managed and untouched: the plugin takes it over.'
skstyle Edited 'Managed, then edited here.'
run --styles-only
[ -f "$DST/Taken.md" ] && [ -f "$DST/Edited.md" ]; ck $? "takeover: baseline installs both without the plugin"
printf '\nlocal edit\n' >> "$DST/Edited.md"
cp "$CLAUDE_CONFIG_DIR/settings.json" "$T/settings.pre-craft"
printf '{"model":"opus","theme":"dark","enabledPlugins":{"craft@pleejr":true}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
skstyle Newer 'Arrives after the plugin is enabled.'
run --check --styles-only
[ "$rc" -eq 1 ]; ck $? "takeover: --check reports the removal as drift"
[ -f "$DST/Taken.md" ]; ck $? "takeover: --check removed nothing"
run --styles-only
[ ! -e "$DST/Taken.md" ]; ck $? "takeover: the untouched managed copy is removed"
! grep -q ' Taken.md$' "$MAN"; ck $? "takeover: its manifest row is gone"
printf '%s' "$out" | grep -q '"outputStyle": "Taken" must become "craft:Taken"'; ck $? "takeover: prints the setting's new name"
[ -f "$DST/Edited.md" ]; ck $? "takeover: an edited copy is left in place"
printf '%s' "$out" | grep -q "'Edited.md' -> left in place"; ck $? "takeover: and says why"
[ ! -e "$DST/Newer.md" ]; ck $? "takeover: the skills store is no longer copied"
printf '%s' "$out" | grep -qE "'(Taken|Edited).md' is no longer in any shared store"; rc_inv=$?
[ "$rc_inv" -ne 0 ]; ck $? "takeover: a taken-over style is not misreported as an orphan"
cp "$T/settings.pre-craft" "$CLAUDE_CONFIG_DIR/settings.json"
rm -f "$SK/Taken.md" "$SK/Edited.md" "$SK/Newer.md" "$DST/Edited.md"


rm -rf "$T"
[ "$fail" -eq 0 ] && echo "shared-output-styles: OK" || { echo "shared-output-styles: FAILURES above"; exit 1; }
