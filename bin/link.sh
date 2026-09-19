#!/usr/bin/env bash
# Symlink skills from this repo into ~/.claude/skills/ so the Skill tool picks them up.
# Idempotent; re-run after adding, renaming, or removing a skill — it also prunes stale
# links to skills this repo no longer has. Never invokes `claude` (see wiki-engine safety rule).
#
# Usage:
#   bin/link.sh                    link every skill (default)
#   bin/link.sh --tags craft       link only skills tagged `craft`
#   bin/link.sh --tags infra,ops   link skills matching ANY of these tags (union)
#   bin/link.sh --force            repoint a name currently linked to another source
#   flags combine, e.g.  bin/link.sh --tags craft --force
#
# Tags come from each SKILL.md `tags:` frontmatter and are validated against the controlled
# vocabulary in bin/allowed-tags.txt (an unknown --tags value is a hard error). `--tags` is
# ADDITIVE per run and never unlinks: it links the matching subset and leaves any already-
# linked skills in place (the prune pass only removes DANGLING links). To slim an install
# down, remove the unwanted links yourself, then re-run with just the tags you want.
#
# A skill whose plugin is enabled in settings (`<plugin>@<marketplace>: true`) is never linked,
# and our own existing link to it is removed: the plugin already loads it as `<plugin>:<name>`.
set -euo pipefail

force=0
req_tags=""
check_args=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)  force=1; shift;;
    --tags)   req_tags="${2:-}"; shift 2;;
    --tags=*) req_tags="${1#--tags=}"; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    # Parse-and-exit, so a caller can reject a bad invocation BEFORE doing work that is
    # awkward to undo. sync.sh uses it: without this its pull lands and only the link step
    # fails, which reads as "it worked" right up until a new skill is missing.
    --check-args) check_args=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ "${check_args:-0}" -eq 1 ] && exit 0
req_tags="${req_tags//,/ }"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_src="$repo_root/skills"
skills_dst="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
allowed_file="$repo_root/bin/allowed-tags.txt"

# A tag is valid iff it is the first field of a non-comment line in allowed-tags.txt.
is_allowed() { grep -qE "^$1[[:space:]]" "$allowed_file"; }

# Fail fast on a bogus --tags value so a typo never silently links nothing.
for r in $req_tags; do
  is_allowed "$r" || { echo "error: unknown tag '$r' (see $allowed_file)" >&2; exit 1; }
done

# Extract inline-flow `tags: [a, b]` from a SKILL.md's frontmatter -> space-separated.
read_tags() {
  awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit}
       f && /^tags:/ { l=$0; sub(/^tags:[ \t]*/,"",l); gsub(/[][]/,"",l); gsub(/,/," ",l);
                       gsub(/[ \t]+/," ",l); sub(/^ /,"",l); sub(/ $/,"",l); print l; exit }' "$1"
}

# Plugin delivery: `skills/<name>` is a symlink into `plugins/<plugin>/skills/<name>`. The
# plugin that owns a skill is read from where that link resolves; whether it is enabled is
# read from user settings, the same file Claude Code reads.
settings="${CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
marketplace="$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$repo_root/.claude-plugin/marketplace.json" 2>/dev/null | head -1)"
plugins_root="$(cd "$repo_root/plugins" 2>/dev/null && pwd -P || true)"
plugin_of() { # <skill dir> -> plugin name, or empty when the skill is not in a plugin
  local p; p="$(cd "$1" && pwd -P)"
  [ -n "$plugins_root" ] || return 0
  case "$p" in "$plugins_root"/*/skills/*) p="${p#"$plugins_root"/}"; echo "${p%%/*}";; esac
}
plugin_enabled() { # <plugin>
  [ -n "$marketplace" ] && grep -qE "\"$1@$marketplace\"[[:space:]]*:[[:space:]]*true" "$settings" 2>/dev/null
}

mkdir -p "$skills_dst"

for dir in "$skills_src"/*/; do
  [ -f "$dir/SKILL.md" ] || continue
  name="$(basename "$dir")"
  target="$skills_dst/$name"
  src="${dir%/}"

  skill_tags="$(read_tags "$dir/SKILL.md")"
  if [ -z "$skill_tags" ]; then
    echo "warn  $name (no tags: frontmatter — add one per skills/skill-author)" >&2
  fi
  # Warn (don't abort) on a skill carrying a tag outside the vocabulary — helps authors.
  for t in $skill_tags; do
    is_allowed "$t" || echo "warn  $name (unknown tag '$t' not in $allowed_file)" >&2
  done

  # Tag filter: when --tags is set, link only skills whose tags intersect the request.
  if [ -n "$req_tags" ]; then
    match=0
    for t in $skill_tags; do for r in $req_tags; do [ "$t" = "$r" ] && match=1; done; done
    if [ "$match" != 1 ]; then
      echo "skip  $name (tags [${skill_tags// /, }] don't match --tags $req_tags)"
      continue
    fi
  fi

  # A skill whose plugin is enabled loads as `<plugin>:<name>`; a link beside it would load
  # it twice. Remove only our own link to it, and leave anything else at that name alone.
  plugin="$(plugin_of "$src")"
  if [ -n "$plugin" ] && plugin_enabled "$plugin"; then
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
      rm -f "$target"
      echo "unlink $name (plugin $plugin@$marketplace provides it)"
    else
      echo "skip  $name (plugin $plugin@$marketplace provides it)"
    fi
    continue
  fi

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
    echo "ok    $name (already linked)"
    continue
  fi
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "skip  $name (a non-symlink already exists at $target)" >&2
    continue
  fi
  if [ -L "$target" ]; then
    # A symlink exists but points elsewhere (the equality check above already
    # handled our own target): another skill source owns this name. Don't hijack it.
    if [ "$force" != 1 ]; then
      echo "skip  $name (symlink already points to $(readlink "$target"); pass --force to repoint)" >&2
      continue
    fi
    echo "warn  $name (repointing from $(readlink "$target"))" >&2
  fi
  # Non-fatal per item: one failed link must not abort the rest of the loop.
  if ln -snf "$src" "$target"; then
    echo "link  $name -> $src"
  else
    echo "warn  $name (link failed; skipping)" >&2
  fi
done

# Prune pass: drop our OWN dangling symlinks left behind when a skill is renamed
# or removed (e.g. redteam -> scrutinize). Strictly scoped — only a broken symlink
# whose target points into THIS repo's skills/ is removed; a healthy link, a real
# file, or a foreign skill source is never touched. (Independent of --tags: a healthy
# link to a filtered-out skill still resolves, so it is never pruned.)
for link in "$skills_dst"/*; do
  [ -L "$link" ] || continue          # symlinks only
  dest="$(readlink "$link")"
  case "$dest" in
    "$skills_src"/*) ;;               # ours to prune
    *) continue;;                     # foreign source — never touched
  esac
  # Two ways a link goes stale, and only the first is a broken symlink:
  #   1. target gone entirely (skill deleted)
  #   2. target still RESOLVES but is no longer a skill — no SKILL.md. This is what
  #      a rename leaves behind: `git mv` moves the tracked files, a gitignored
  #      __pycache__/ keeps the old directory alive, and the symlink therefore still
  #      resolves. Testing only `-e` left that phantom installed, and every installed
  #      skill spends context at session start whether or not it can ever be invoked.
  if [ -e "$link" ] && [ -f "$link/SKILL.md" ]; then
    continue
  fi
  if [ -e "$link" ]; then
    reason="no SKILL.md"
  else
    reason="target gone"
  fi
  rm -f "$link"
  echo "prune $(basename "$link") ($reason -> $dest)" >&2
done

# Install the session-start check drop-in into the wiki-engine's session-checks.d seam so
# the engine banner can surface "skills: first run / catch up" (idempotent symlink; the
# engine runs it deterministically). Harmless if no engine/vault is present on this machine.
checks_dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-checks.d"
check_src="$repo_root/bin/session-check.sh"
if [ -f "$check_src" ]; then
  mkdir -p "$checks_dst"
  if [ "$(readlink "$checks_dst/pleejr-skills.sh" 2>/dev/null)" != "$check_src" ]; then
    ln -snf "$check_src" "$checks_dst/pleejr-skills.sh"
    echo "link  session-check -> $checks_dst/pleejr-skills.sh"
  fi
fi
