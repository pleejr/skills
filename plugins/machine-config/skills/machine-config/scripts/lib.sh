#!/usr/bin/env bash
# lib.sh — shared helpers for the machine-config scripts. Sourced, not run.
#
# Deliberately assumes NOTHING about any particular vault, wiki, or directory layout: the
# config repo is located from configuration, never hardcoded, so this works for anyone who
# just wants their Claude Code config backed up.

# Where the config-repo path is remembered, in precedence order:
#   1. $MACHINE_CONFIG_REPO         — explicit, wins (useful for tests and one-offs)
#   2. ~/.claude/machine-config-repo — a one-line pointer file, written once per machine
# Nothing is guessed: a wrong guess would snapshot into, or restore from, the wrong repo.
mc_repo() {
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -n "${MACHINE_CONFIG_REPO:-}" ]; then printf '%s\n' "$MACHINE_CONFIG_REPO"; return 0; fi
  if [ -f "$cfg/machine-config-repo" ]; then
    local p; p="$(tr -d '[:space:]' < "$cfg/machine-config-repo")"
    case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
  fi
  return 1
}

mc_repo_or_die() {
  local r; r="$(mc_repo)" || {
    echo "machine-config: no config repo set." >&2
    echo "  Point at one:  echo /path/to/config-repo > ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/machine-config-repo" >&2
    echo "  Or create one: scripts/init.sh /path/to/config-repo" >&2
    return 2
  }
  [ -d "$r" ] || { echo "machine-config: config repo '$r' does not exist" >&2; return 2; }
  printf '%s\n' "$r"
}

mc_cfg() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# Where this machine keeps its git clones — backup.sh records each one's remote so restore.sh
# can print a clone list. Override for any other layout; the default is only a default.
MC_REPOS_DIR="${MC_REPOS_DIR:-$HOME/Documents/repos}"
mc_host() { printf '%s\n' "${MACHINE_CONFIG_HOST:-$(hostname -s)}"; }

# Config files worth carrying. Everything else under ~/.claude is state, not config —
# conversation history, telemetry, caches — which is private, large, and pointless to restore.
MC_FILES="settings.json CLAUDE.md skill-sources keybindings.json skill-config.env"

# Directories under ~/.claude carried RECURSIVELY.
#
#   bin, hooks    the scripts settings.json points at by absolute path — hook and statusLine
#                 commands. Without them a restore hands back a settings.json referencing
#                 scripts that do not exist: a dead statusLine and a hook that errors on every
#                 tool call.
#   skill-state   the mode files those hooks READ. Carrying the wiring without the state it
#                 reads restores a hook that runs, finds nothing, and correctly treats
#                 missing-as-off — so the mode is silently gone while every file it depends on
#                 is present. Skills write their durable mode here for exactly that reason;
#                 see the expand-acronyms skill.
#   output-styles the custom output styles that settings.json's `outputStyle` names. Same shape
#                 of failure again: restore the setting without the Markdown file it points at
#                 and the config references a style that is not on disk. These are hand-authored
#                 prose — irreplaceable in the way a cache never is.
#
# Both failures look like a completed restore, which is the worst kind. Captured wholesale
# rather than by filename so a newly-added hook — or a newly-added mode file — is covered
# without anyone remembering to update a list; that is the whole point of a directory here,
# and the reason to add a skill's state to this dir rather than another entry in MC_FILES.
# Three guards make wholesale capture safe: every file is secret-scanned before capture (these
# dirs sit alongside credential files like .slack-webhook), and dotfiles and symlinks inside
# them are skipped — a secret dropped in here is conventionally a dotfile, a scratch file is
# conventionally named as one, and a symlink would only encode this machine's paths.
MC_DIRS="bin hooks skill-state output-styles"

# Anything credential-shaped. Fail closed: a snapshot that silently commits a token is worse
# than no snapshot, because it is a leak wearing a green checkmark.
MC_SECRET_RE='(ghp_|github_pat_|sk-ant-|xox[baprs]-|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|"(api_?key|secret|token|password)"[[:space:]]*:[[:space:]]*"[^"]{8,})'

# Anything MACHINE-LOCAL inside a file that shared/ proposes to install on every machine.
# The settings denylist next door is by KEY, and a Markdown file has no keys — so the analogue
# is the test the boundary decision states in prose: if it names a path, a repo, or grants
# authority, it is machine-local. A home path is the load-bearing half: it is the thing that
# does not exist on the other machine, and the thing that carries an identity across when the
# two boundaries are kept in step by hand.
MC_MACHINE_LOCAL_RE='(/Users/|/home/|\$HOME|~/)'

# Portable content fingerprint, for telling "shared/ changed" from "the operator edited this
# copy". cksum is POSIX and present everywhere; this detects an edit, it defends against no
# adversary, so a stronger digest would buy nothing and cost a per-platform branch.
#
# The space is stripped rather than kept, which concatenates checksum and byte count, so two
# files could in principle agree by shifting the digit boundary (259473776+95038 reads the same
# as 2594737769+5038). Left as is DELIBERATELY: the string is deterministic per file, which is
# all an equality test needs, and changing the format now would invalidate every manifest in
# existence — turning each machine's next clean update into a refusal. Do not "fix" this
# without migrating the manifests.
mc_sum() { cksum < "$1" | tr -d ' '; }

# The SECOND store of shared output styles: this skills repo itself, at
# plugins/craft/output-styles/ (mc_skills_store).
#
# The config repo is per BOUNDARY — one for work, one for personal, never remotes of each
# other — so its shared/ can carry a style between two work machines and can NEVER carry one
# across the boundary. A skills repo is the channel that already crosses it: it is consumed
# from both setups by contract, which is also the reason it must carry no boundary-specific
# data of its own.
#
# Located from the library's own path, never claimed by position alone: the directory two
# levels above scripts/ has to prove it is a skills repo before it counts. $MC_SKILLS_REPO
# overrides, which is how the fixture pass isolates itself from the real one — without that
# override the tests would silently read whatever the operator's real repo happens to hold.
mc_skills_repo() {
  if [ -n "${MC_SKILLS_REPO:-}" ]; then
    [ -d "$MC_SKILLS_REPO" ] && printf '%s\n' "$MC_SKILLS_REPO"
    return 0
  fi
  # Walk up rather than count levels: the skill moved from skills/<name>/ to
  # plugins/<plugin>/skills/<name>/, and a fixed depth silently stopped finding the repo.
  # A plugin installed into the cache has no repo above it, and correctly finds none.
  local dir i
  dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
  for i in 1 2 3 4 5 6; do
    dir="$(dirname "$dir")"
    # The styles plugin's directory, not bin/link.sh: link.sh is retired with the symlink
    # delivery, and keying on it would make the repo stop being found the day it goes.
    if [ -f "$dir/.claude-plugin/marketplace.json" ] && [ -d "$dir/plugins/$MC_STYLES_PLUGIN" ]; then
      printf '%s\n' "$dir"; return 0
    fi
  done
  return 0
}

# Every directory shared output styles may come from, one per line; a store that does not
# exist is simply not emitted.
#
# There is deliberately NO precedence between them. A name carried by both is a CONFLICT the
# caller must refuse, not a race one store quietly wins — the two have different reaches (one
# boundary versus both), so silently preferring either is how a machine ends up running prose
# its operator believes lives somewhere else, and updates the other copy forever.
#
# The skills store stands down when the `craft` plugin is enabled: Claude Code then loads those
# styles itself as `craft:<name>`, and a copy in ~/.claude/output-styles/ would list each one
# twice under two names. See mc_styles_plugin_dir and apply.sh's stand-down pass.
mc_styles_dirs() { # <config-repo-or-empty>
  local repo="${1:-}" sk
  [ -n "$repo" ] && [ -d "$repo/shared/output-styles" ] && printf '%s\n' "$repo/shared/output-styles"
  mc_plugin_enabled "$MC_STYLES_PLUGIN" && return 0
  sk="$(mc_skills_store)"
  [ -n "$sk" ] && [ -d "$sk" ] && printf '%s\n' "$sk"
  return 0
}

# The plugin that ships the skills repo's output styles, and where they sit in the repo. The
# store moved from the repo root into this plugin so one directory serves both deliveries:
# the plugin loads it directly, and a machine without the plugin still has apply.sh copy it.
MC_STYLES_PLUGIN=craft
mc_skills_store() {
  local sk; sk="$(mc_skills_repo)"
  [ -n "$sk" ] && printf '%s\n' "$sk/plugins/$MC_STYLES_PLUGIN/output-styles"
  return 0
}

# Is <plugin> enabled in user settings, from any marketplace? Read from the same file Claude
# Code reads.
mc_plugin_enabled() { # <plugin>
  grep -qE "\"$1@[^\"]+\"[[:space:]]*:[[:space:]]*true" "$(mc_cfg)/settings.json" 2>/dev/null
}

# The output-styles directory the enabled styles plugin is loading, or empty. The repo copy
# first, because a directory marketplace runs its plugins in place; otherwise the installed
# copy that installed_plugins.json names.
mc_styles_plugin_dir() {
  mc_plugin_enabled "$MC_STYLES_PLUGIN" || return 0
  local d; d="$(mc_skills_store)"
  if [ -n "$d" ] && [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
  command -v jq >/dev/null 2>&1 || return 0
  d="$(jq -r --arg p "$MC_STYLES_PLUGIN@" '.plugins | to_entries[] | select(.key | startswith($p)) | .value[0].installPath // empty' \
        "$(mc_cfg)/plugins/installed_plugins.json" 2>/dev/null | head -1)"
  [ -n "$d" ] && [ -d "$d/output-styles" ] && printf '%s\n' "$d/output-styles"
  return 0
}

# The name Claude Code gives a plugin-shipped style: `<plugin>:<frontmatter name>`, or the file
# stem when the frontmatter has none. Read from the 2.1.277 loader; the docs do not say.
mc_plugin_style_name() { # <style file>
  local n
  n="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f&&/^name:/{sub(/^name:[ \t]*/,"");gsub(/^["\x27]|["\x27]$/,"");print;exit}' "$1")"
  [ -n "$n" ] || n="$(basename "$1" .md)"
  printf '%s:%s\n' "$MC_STYLES_PLUGIN" "$n"
}

# Was this script reached through a legacy wiring — a session-checks.d drop-in link — while the
# machine-config plugin carries the same hook? Then the plugin runs it, and this copy must stay
# silent or every session would do the work twice. <path> is the caller's own $0 / BASH_SOURCE.
mc_legacy_standdown() { # <path the script was invoked as>
  case "$1" in "$(mc_cfg)/session-checks.d/"*) mc_plugin_enabled machine-config ;; *) return 1 ;; esac
}

# Where this machine records which shared output styles it installed, and the fingerprint it
# installed. Without it, "this file differs from shared/" cannot distinguish a shared update
# (safe to apply) from prose the operator wrote here (must never be overwritten) — and these
# files are hand-authored, irreplaceable in the way a cache never is.
mc_styles_manifest() { printf '%s\n' "$(mc_cfg)/.machine-config-shared-styles"; }

# Read the Claude CLI version WITHOUT executing it. These scripts run from a SessionStart
# drop-in, and that contract forbids invoking `claude` at all — `claude --version` could not
# recurse, but honouring the stricter rule means nobody has to re-derive that judgement on a
# later edit. The native installer symlinks the launcher at a versioned path.
mc_claude_version() {
  local bin; bin="$(command -v claude 2>/dev/null)"
  if [ -n "$bin" ] && [ -L "$bin" ]; then basename "$(readlink "$bin")"; else echo unknown; fi
}
