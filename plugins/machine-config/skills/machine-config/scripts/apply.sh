#!/usr/bin/env bash
# apply.sh — merge the shared, boundary-free Claude Code preferences into this machine's
# ~/.claude/settings.json, and install the shared output styles. Deterministic; git + jq
# only; NEVER spawns `claude`.
#
# MERGE, NEVER OVERWRITE. The shared file carries only machine-invariant preferences; this
# machine's own wiring (hooks, statusLine, permissions, autoMode) is left exactly as it is.
# That is the whole conflict story: machine-specific config never enters git, so there is
# nothing to conflict over, and the shared file stays small enough that a real conflict is
# a two-line fix rather than a merge of two whole settings files.
#
# FAIL-CLOSED DENYLIST. Some keys must never travel between machines, and — because the
# personal and work instances of this repo are separate repos kept in step by hand — a
# mistake on one side must not be able to push authority onto the other. So this script
# refuses to apply them even if they appear in shared/, rather than trusting the file:
#   hooks / statusLine  — carry absolute paths that name a vault and don't exist elsewhere
#   permissions         — grants tool authority; must be decided per machine
#   autoMode            — grants the agent standing approval; must be decided per machine
#   env                 — routinely holds machine-local paths and endpoints
# A denied key is reported and skipped, never silently dropped.
#
# SHARED OUTPUT STYLES, the second half. An output style is the clearest case the shared
# layer was meant for — hand-authored prose about how to write, naming no path, no repo and
# no authority — and it had no route: settings.json's `outputStyle` names a file, and only
# machines/<host>/ ever carried the file, so the style reached exactly one machine's
# replacement and no second machine at all.
#
# TWO STORES, DIFFERENT REACH. Styles are collected from both of these, and installed into
# ~/.claude/output-styles/:
#   <config repo>/shared/output-styles/   every machine in ONE boundary
#   <skills repo>/output-styles/          every machine that syncs the skills repo, which
#                                         is consumed from both boundaries by contract
# The config repo is per boundary — work and personal are separate repos, never remotes of
# each other — so it structurally cannot carry a style from a work laptop to a personal one.
# The skills repo already crosses that gap. Which is also its constraint: a style published
# there must carry no boundary-specific data, and the guards below cannot check that for you
# (see --promote).
#
# The config repo is REQUIRED for the settings half and OPTIONAL for the styles half. A
# machine may legitimately have only the skills store — a second laptop that wants the shared
# prose and keeps its own config elsewhere — and dying there would withhold the styles from
# exactly the machine this second store exists to reach.
#
# A NAME IN BOTH STORES IS REFUSED, never resolved. The two have different reaches, so
# silently preferring either installs prose the operator believes lives somewhere else, and
# then tracks updates from the wrong copy forever. Delete the one you do not want.
#
# It carries FILES rather than keys, so its two guards are the file-shaped analogues of the
# denylist above:
#   1. A shared style naming a home path, or carrying credential-shaped content, is REFUSED —
#      the boundary rule is "if it names a path, a repo, or grants authority, it is
#      machine-local", and a Markdown file has no keys to test that on.
#   2. A local style this machine did not install, or installed and then EDITED, is never
#      overwritten. These are irreplaceable prose; `--force` will overwrite, after a backup.
# A style deleted from every store is reported as orphaned and LEFT IN PLACE — removing a
# config file the operator can still see is not a merge, and nothing here should delete work.
#
# Usage:
#   bin/apply.sh                     merge shared prefs + install shared styles (backs up first)
#   bin/apply.sh --check             report what WOULD change; exit 1 if drifted, 0 if in sync
#   bin/apply.sh --force             also overwrite a locally-edited shared style (backup alongside)
#   bin/apply.sh --promote NAME      publish this machine's style into a shared store
#   bin/apply.sh --promote NAME --to skills|config    ...naming which store, when it is ambiguous
#   bin/apply.sh --styles-only       do only the output-style half (settings.json untouched)
#   bin/apply.sh --settings-only     do only the settings half (output styles untouched)
#
# HALF-SELECTORS, and why they exist. The two halves have different blast radii: the styles
# half copies prose files a store already owns, while the settings half rewrites this
# machine's settings.json. `session-apply.sh` runs UNATTENDED at session start, so it takes
# only the narrow half; settings drift stays a thing a human is told about and decides.
set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
CFG="$(mc_cfg)"
settings="$CFG/settings.json"

# The config repo is optional here, unlike everywhere else in this skill — see the header.
repo="$(mc_repo 2>/dev/null)" || repo=""
if [ -n "$repo" ] && [ ! -d "$repo" ]; then
  echo "apply: config repo '$repo' does not exist" >&2
  exit 2
fi
skills_repo="$(mc_skills_repo)"
if [ -z "$repo" ] && [ -z "$skills_repo" ]; then
  mc_repo_or_die >/dev/null
  exit 2
fi
shared=""
[ -n "$repo" ] && shared="$repo/shared/settings.shared.json"

check_only=0; force=0; promote=""; promote_to=""
do_settings=1; do_styles=1; half=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --force) force=1; shift ;;
    --styles-only) do_settings=0; half="--styles-only"; shift ;;
    --settings-only) do_styles=0; half="--settings-only"; shift ;;
    --promote) promote="${2:-}"; shift 2 ;;
    --promote=*) promote="${1#--promote=}"; shift ;;
    --to) promote_to="${2:-}"; shift 2 ;;
    --to=*) promote_to="${1#--to=}"; shift ;;
    *) echo "apply: unknown argument '$1' (--check | --force | --styles-only | --settings-only | --promote NAME [--to skills|config])" >&2; exit 2 ;;
  esac
done
if [ -n "$promote" ] && { [ "$check_only" -eq 1 ] || [ "$force" -eq 1 ]; }; then
  echo "apply: --promote is its own mode; do not combine it with --check or --force" >&2
  exit 2
fi
# Asking for both halves exclusively is a contradiction, and picking one silently is how a
# caller ends up applying a half it believed it had excluded.
if [ "$do_settings" -eq 0 ] && [ "$do_styles" -eq 0 ]; then
  echo "apply: --styles-only and --settings-only are mutually exclusive — each names the half to keep" >&2
  exit 2
fi
if [ -n "$promote" ] && [ -n "$half" ]; then
  echo "apply: --promote is its own mode; do not combine it with $half" >&2
  exit 2
fi
# The settings half REQUIRES the config repo. Without this it would run to completion having
# done nothing, and exit 0 — a caller that asked for settings and got silence.
if [ "$do_styles" -eq 0 ] && [ -z "$repo" ]; then
  echo "apply: --settings-only needs a config repo, and this machine has none" >&2
  exit 2
fi
if [ -n "$promote_to" ] && [ -z "$promote" ]; then
  echo "apply: --to only means something with --promote" >&2
  exit 2
fi
case "${promote_to:-}" in
  ''|skills|config) ;;
  *) echo "apply: --to takes 'skills' or 'config', not '$promote_to'" >&2; exit 2 ;;
esac
# --check reports; --force writes. Asking for both is a contradiction rather than a harmless
# combination, and silently letting one win is how a dry run turns out to have written.
if [ "$check_only" -eq 1 ] && [ "$force" -eq 1 ]; then
  echo "apply: --check and --force are mutually exclusive — one reports, the other writes" >&2
  exit 2
fi

# Manifest helpers, defined up here because BOTH modes below use them — --promote records
# that this machine now agrees with the store, and the apply phase reads the same rows.
manifest="$(mc_styles_manifest)"

# Read the manifest into a lookup. A missing manifest is not an error: it is what every
# machine looks like before its first apply, and what a machine looks like after a restore
# put the files there by another route.
mc_recorded() { # <name> -> the fingerprint this machine installed, or empty
  [ -f "$manifest" ] || return 0
  awk -v n="$1" '$2 == n { print $1; exit }' "$manifest"
}
mc_record() { # <name> <sum> — replace this name's row, keep the rest
  local tmp; tmp="$manifest.tmp.$$"
  { [ -f "$manifest" ] && awk -v n="$1" '$2 != n' "$manifest"
    printf '%s %s\n' "$2" "$1"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$manifest"
}
mc_forget() { # <name> — drop this name's row
  local tmp; tmp="$manifest.tmp.$$"
  [ -f "$manifest" ] || return 0
  awk -v n="$1" '$2 != n' "$manifest" > "$tmp" 2>/dev/null && mv -f "$tmp" "$manifest"
}

# The stores, most-local first, and the paths within them.
styles_dirs="$(mc_styles_dirs "$repo")"
styles_dst="$CFG/output-styles"
config_store=""; [ -n "$repo" ] && config_store="$repo/shared/output-styles"
skills_store="$(mc_skills_store)"

# First store carrying <name>, or empty. Order follows mc_styles_dirs; callers that care
# about a name living in more than one store test for that FIRST, because this answers
# "where is it" and not "is it unambiguous".
style_path() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -e "$d/$1" ] && { printf '%s\n' "$d/$1"; return 0; }
  done <<EOF
$styles_dirs
EOF
  return 1
}

# ---------------------------------------------------------------------------------------
# --promote: publish a local style INTO a shared store. The other direction, and the
# missing half.
# ---------------------------------------------------------------------------------------
# Without this there is no publish path at all. A style is edited where it is used —
# ~/.claude/output-styles/ — and autosave then snapshots it into machines/<host>/, the
# RESTORE half, which no other machine reads. The shared store never learns, and worse, that
# machine's own next apply.sh refuses the file as an operator edit. So the machine that
# produced the improvement is the one that silently stops receiving updates for it.
#
# The guards run HARDER here than on the way in: this is the direction in which a home path
# or a credential would ENTER a shared store and be handed to every other machine.
#
# It does NOT commit. Committing is what publishes to the other machines, and this repo's
# rule is that a shared store is hand-committed while autosave stages only machines/<host>/.
# The commands are printed instead.
if [ -n "$promote" ]; then
  name="${promote%.md}.md"
  src="$CFG/output-styles/$name"

  if [ ! -f "$src" ]; then
    echo "apply: no output style '$name' at $src" >&2
    if [ -d "$CFG/output-styles" ]; then
      echo "apply: styles on this machine:" >&2
      find "$CFG/output-styles" -type f -name '*.md' -exec basename {} \; 2>/dev/null | sed 's/^/  /' >&2
    fi
    exit 2
  fi

  # Which store? Where the style ALREADY lives wins over any default, because promoting a
  # style into the store it is not in is how one name ends up in two — the conflict this
  # script refuses on the way back in. Only a genuinely new name falls through to a default.
  in_config=0; [ -n "$config_store" ] && [ -e "$config_store/$name" ] && in_config=1
  in_skills=0; [ -n "$skills_store" ] && [ -e "$skills_store/$name" ] && in_skills=1
  if [ "$in_config" -eq 1 ] && [ "$in_skills" -eq 1 ]; then
    echo "apply: REFUSING to promote '$name' — it is already in BOTH stores, which is the conflict apply refuses:" >&2
    echo "  $config_store/$name" >&2
    echo "  $skills_store/$name" >&2
    echo "apply:   delete the copy you do not want, then promote again" >&2
    exit 3
  fi

  target="$promote_to"
  if [ -z "$target" ]; then
    if [ "$in_config" -eq 1 ]; then target=config
    elif [ "$in_skills" -eq 1 ]; then target=skills
    # A new name defaults to the store that reaches BOTH boundaries — that is what sharing
    # a style usually means, and the narrower store is one flag away.
    elif [ -n "$skills_store" ]; then target=skills
    else target=config
    fi
  fi

  case "$target" in
    skills)
      [ -n "$skills_repo" ] || { echo "apply: no skills repo found, so --to skills has nowhere to write" >&2; exit 2; }
      store="$skills_store"; store_repo="$skills_repo"; store_rel="${skills_store#"$skills_repo"/}/$name"
      ;;
    config)
      [ -n "$repo" ] || { echo "apply: no config repo on this machine, so --to config has nowhere to write" >&2; exit 2; }
      store="$config_store"; store_repo="$repo"; store_rel="shared/output-styles/$name"
      ;;
  esac
  dst="$store/$name"

  if grep -aEq "$MC_MACHINE_LOCAL_RE" "$src"; then
    echo "apply: REFUSING to promote '$name' — it names a home path, which does not exist on the machines that would receive it" >&2
    grep -anE "$MC_MACHINE_LOCAL_RE" "$src" | sed 's/^/  line /' >&2
    exit 3
  fi
  if grep -aEq "$MC_SECRET_RE" "$src"; then
    echo "apply: REFUSING to promote '$name' — credential-shaped content; a shared store is pushed to a remote" >&2
    exit 3
  fi

  src_sum="$(mc_sum "$src")"
  if [ -f "$dst" ] && [ "$(mc_sum "$dst")" = "$src_sum" ]; then
    echo "apply: '$name' is already what $store carries — nothing to promote"
    exit 0
  fi

  mkdir -p "$store" || { echo "apply: cannot create $store" >&2; exit 2; }
  if [ -f "$dst" ]; then
    echo "apply: replacing the shared '$name' ($(wc -c < "$dst" | tr -d ' ') bytes) with this machine's ($(wc -c < "$src" | tr -d ' ') bytes)"
  else
    echo "apply: promoting '$name' to $store for the first time ($(wc -c < "$src" | tr -d ' ') bytes)"
  fi
  cp "$src" "$dst" || { echo "apply: copy failed" >&2; exit 2; }
  mc_record "$name" "$src_sum"   # this machine and the store now agree; it owns the copy here

  # The guards above are mechanical: a home path and a credential have a shape. Whether the
  # PROSE names an employer, a ticket, a colleague or an internal system does not, and the
  # skills store is read from both boundaries — so this is said out loud rather than checked,
  # because a guard that cannot see the thing it claims to check is worse than none.
  if [ "$target" = skills ]; then
    echo "apply: NOTE — the skills store is read from BOTH boundaries. Nothing here can tell whether this prose names an employer, a ticket, a colleague or an internal system; read it before you commit."
  fi

  echo "apply: written to $dst — NOT committed, because committing is what publishes it:"
  echo "  git -C $store_repo add $store_rel"
  echo "  git -C $store_repo commit -m 'shared: update the $name output style'"
  echo "  git -C $store_repo push"
  exit 0
fi

refused=0   # something a shared store asked for did NOT happen; see the exit note below
drift=0

# ---------------------------------------------------------------------------------------
# shared settings — the config repo's half, and the only half that requires it
# ---------------------------------------------------------------------------------------
if [ -n "$repo" ] && [ "$do_settings" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "apply: jq is required" >&2; exit 2; }
  [ -f "$shared" ] || { echo "apply: no $shared" >&2; exit 2; }
  jq empty "$shared" 2>/dev/null || { echo "apply: $shared is not valid JSON" >&2; exit 2; }

  DENY='["hooks","statusLine","permissions","autoMode","env"]'

  # Report and strip anything on the denylist before it can reach the merge.
  denied="$(jq -r --argjson d "$DENY" 'keys_unsorted - (keys_unsorted - $d) | .[]' "$shared")"
  if [ -n "$denied" ]; then
    for k in $denied; do
      echo "apply: REFUSING '$k' from shared/ — machine-local by policy, decide it per machine" >&2
      refused=1
    done
  fi
  safe_shared="$(jq --argjson d "$DENY" 'delpaths([$d[] | [.]])' "$shared")"

  [ -f "$settings" ] || echo '{}' > "$settings"
  jq empty "$settings" 2>/dev/null || { echo "apply: $settings is not valid JSON — fix it first" >&2; exit 2; }

  # Shallow merge: shared wins for the keys it declares, everything else is untouched.
  merged="$(jq -s '.[0] * .[1]' "$settings" <(printf '%s' "$safe_shared"))"

  if [ "$merged" = "$(jq . "$settings")" ]; then
    echo "apply: settings in sync (no change)"
  else
    drift=1
    # Show the drift either way — a silent config write is how a machine ends up different
    # from what its owner believes it is.
    echo "apply: keys that differ from shared:"
    jq -n --argjson cur "$(jq . "$settings")" --argjson sh "$safe_shared" \
      '$sh | to_entries[] | select(.value != ($cur[.key])) | "  \(.key): \($cur[.key] // "unset") -> \(.value)"' -r
    if [ "$check_only" -eq 0 ]; then
      cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
      printf '%s\n' "$merged" > "$settings"
      echo "apply: merged shared prefs into $settings (backup alongside)"
    fi
  fi
fi

# ---------------------------------------------------------------------------------------
# shared output styles — collected from every store
# ---------------------------------------------------------------------------------------
# Guarded as one block rather than reindented: the body below is unchanged from when it was
# unconditional, so a diff against it stays readable.
if [ "$do_styles" -eq 1 ]; then
# name<TAB>path for every candidate, sorted by name so the duplicate test below is a plain
# `uniq -d` rather than a nested walk.
cands=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(basename "$f")"
    # Same skips backup.sh applies to these directories: a dotfile is the shape a dropped
    # secret or a scratch file takes, and -type f already excludes symlinks, which would only
    # encode one machine's paths.
    case "$n" in .*) continue ;; esac
    cands="${cands}${n}	${f}
"
  done < <(find "$d" -type f -name '*.md' 2>/dev/null | sort)
done < <(printf '%s\n' "$styles_dirs")
cands="$(printf '%s' "$cands" | sort)"

# A name in more than one store is refused rather than resolved, and named in every store it
# was found in — "it is a duplicate" is not actionable without the two paths to choose between.
dupes="$(printf '%s\n' "$cands" | cut -f1 | grep -v '^$' | uniq -d)"
if [ -n "$dupes" ]; then
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "apply: REFUSING output style '$n' — carried by more than one shared store, which have different reach:" >&2
    printf '%s\n' "$cands" | awk -F'\t' -v n="$n" '$1 == n { print "  " $2 }' >&2
    echo "apply:   delete the copy you do not want; nothing here will pick for you" >&2
    refused=1
  done <<EOF
$dupes
EOF
fi

while IFS="$(printf '\t')" read -r name src; do
  [ -n "${name:-}" ] || continue
  # Already refused above as a conflict; installing either copy is the thing we declined.
  printf '%s\n' "$dupes" | grep -qxF "$name" && continue

  # Guard 1 — the file-shaped analogue of the key denylist above.
  if grep -aEq "$MC_MACHINE_LOCAL_RE" "$src" 2>/dev/null; then
    echo "apply: REFUSING output style '$name' — it names a home path, so it is machine-local by the same rule as hooks/env" >&2
    refused=1; continue
  fi
  if grep -aEq "$MC_SECRET_RE" "$src" 2>/dev/null; then
    echo "apply: REFUSING output style '$name' — credential-shaped content; a shared store must never carry one" >&2
    refused=1; continue
  fi

  src_sum="$(mc_sum "$src")"
  dst="$styles_dst/$name"

  if [ ! -e "$dst" ]; then
    drift=1
    echo "apply: output style '$name' -> not installed here"
    if [ "$check_only" -eq 0 ]; then
      mkdir -p "$styles_dst" && cp "$src" "$dst" && mc_record "$name" "$src_sum"
      echo "apply: installed $dst"
    fi
    continue
  fi

  dst_sum="$(mc_sum "$dst")"
  if [ "$dst_sum" = "$src_sum" ]; then
    # Byte-identical, so nothing is at risk either way. Adopt it into the manifest if it
    # arrived by another route (a restore, a hand copy) — otherwise the very next shared
    # update would read as an operator edit and refuse forever.
    #
    # SAY SO. This branch used to be silent, and silence here is the one thing an operator
    # cannot act on: on a machine already running the style, `--check` printed nothing about
    # styles at all, so "is this managed?" and "does this script even see it?" looked the
    # same — and a real run then wrote the manifest that the silent --check had not
    # predicted. Reported, and deliberately NOT counted as drift: `--check`'s exit 1 means
    # YOUR CONFIG would change, and adopting an identical file changes no config.
    if [ "$(mc_recorded "$name")" != "$src_sum" ]; then
      if [ "$check_only" -eq 1 ]; then
        echo "apply: output style '$name' -> already here and identical; would be recorded as managed (no content change)"
      else
        mc_record "$name" "$src_sum"
        echo "apply: output style '$name' -> adopted as managed (identical, nothing rewritten)"
      fi
    fi
    continue
  fi

  if [ "$(mc_recorded "$name")" = "$dst_sum" ]; then
    # We installed it and it is untouched since, so the difference is the store moving on.
    drift=1
    echo "apply: output style '$name' -> shared copy updated"
    if [ "$check_only" -eq 0 ]; then
      cp "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
      cp "$src" "$dst" && mc_record "$name" "$src_sum"
      echo "apply: updated $dst (backup alongside)"
    fi
    continue
  fi

  # Differs, and this machine cannot show it wrote what is there — an operator edit, or a
  # style that predates the shared one under the same name. Never overwritten on its own.
  drift=1
  if [ "$force" -eq 1 ]; then
    cp "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
    cp "$src" "$dst" && mc_record "$name" "$src_sum"
    echo "apply: FORCED output style '$name' over a local copy this machine did not install (backup alongside)"
  else
    echo "apply: REFUSING output style '$name' — the copy here differs and this machine did not install it; it is hand-authored prose, not a cache" >&2
    echo "apply:   keep yours: do nothing · take shared: $0 --force (backs the local one up first)" >&2
    refused=1
  fi
done <<EOF
$cands
EOF

# STAND-DOWN. With the styles plugin enabled, Claude Code loads the skills store itself as
# `<plugin>:<name>`, so a copy this machine installed earlier would list the style twice under
# two names. A copy is removed only when the manifest shows this machine installed it and it is
# byte-for-byte what was installed — the same proof the update branch above requires. An edited
# copy is operator prose and stays. The setting that names it is NOT rewritten (it may live in a
# project's settings); the new name is printed instead, because a stale name silently drops the
# session back to the default style.
plugin_dir="$(mc_styles_plugin_dir)"
stood_down=""
if [ -n "$plugin_dir" ] && [ -f "$manifest" ] && [ -d "$styles_dst" ]; then
  while read -r rec_sum name; do
    [ -n "${name:-}" ] || continue
    [ -f "$plugin_dir/$name" ] || continue
    style_path "$name" >/dev/null && continue   # still carried by the config store: its row
    stood_down="$stood_down $name"
    dst="$styles_dst/$name"
    new_name="$(mc_plugin_style_name "$plugin_dir/$name")"
    if [ ! -e "$dst" ]; then
      [ "$check_only" -eq 0 ] && mc_forget "$name"
      continue
    fi
    if [ "$(mc_sum "$dst")" != "$rec_sum" ]; then
      echo "apply: output style '$name' -> left in place: the $MC_STYLES_PLUGIN plugin now ships it as '$new_name', but the copy here was edited after install"
      continue
    fi
    drift=1
    old_name="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f&&/^name:/{sub(/^name:[ \t]*/,"");print;exit}' "$dst")"
    if [ "$check_only" -eq 1 ]; then
      echo "apply: output style '$name' -> would be removed; the $MC_STYLES_PLUGIN plugin ships it as '$new_name'"
    else
      rm -f "$dst" && mc_forget "$name"
      echo "apply: removed $dst — the $MC_STYLES_PLUGIN plugin ships it as '$new_name'"
    fi
    echo "apply:   a setting of \"outputStyle\": \"${old_name:-${name%.md}}\" must become \"$new_name\""
  done < "$manifest"
fi

# A style dropped from EVERY store is REPORTED, never deleted. Removing a config file its
# owner can still see is not a merge, and an orphan costs nothing but a line of output.
if [ -f "$manifest" ] && [ -d "$styles_dst" ]; then
  while read -r _sum name; do
    [ -n "${name:-}" ] || continue
    style_path "$name" >/dev/null && continue
    case " $stood_down " in *" $name "*) continue ;; esac
    [ -e "$styles_dst/$name" ] || continue
    echo "apply: output style '$name' is no longer in any shared store — left in place; delete it yourself if you want it gone"
  done < "$manifest"
fi
fi   # end of the output-styles half

# --check reports the status the real run WOULD return, refusal first. It used to exit 0
# when the only finding was a guard refusal (a shared style naming a home path changes
# nothing here, so `drift` stayed 0) — a dry run that disagrees with the real run, which is
# the same class this file already fixed once in the adopt branch.
if [ "$check_only" -eq 1 ]; then
  [ "$refused" -eq 1 ] && exit 3
  [ "$drift" -eq 1 ] && exit 1
  exit 0
fi
# Exit 3 = applied what it could, and refused at least one thing a shared store asked for. A
# refusal that exits 0 is indistinguishable from a clean apply, which is the fail-open shape
# this script's own header warns about; making the two events distinguishable costs nothing.
[ "$refused" -eq 1 ] && exit 3
exit 0
