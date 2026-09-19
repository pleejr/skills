#!/usr/bin/env bash
# gen-readme-skills.sh — regenerate the Skills table in README.md by scanning
# skills/*/SKILL.md frontmatter, so the table never drifts from the actual skills.
# Ported from wiki-engine's gen-skills-index.sh. Deterministic (sorted by name);
# don't hand-edit the table between the sentinels.
#
# Each row:  | [`<name>`](skills/<name>/SKILL.md) | <cell> |
# cell = frontmatter `summary`, falling back to the first sentence of `description`.
# Handles plain scalars and folded/literal block scalars (`>-`, `|`, ...).
#
# The table is spliced between these sentinels in README.md:
#   <!-- skills:start -->
#   ... generated table ...
#   <!-- skills:end -->
#
# Usage:
#   bin/gen-readme-skills.sh            update README.md in place
#   bin/gen-readme-skills.sh --stdout   print the generated table only
#   bin/gen-readme-skills.sh --check    exit 1 if README.md is out of date (no write)
# Never invokes `claude` (see wiki-engine safety rule).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/skills"
README="$REPO_ROOT/README.md"

MODE="write"
while [ $# -gt 0 ]; do
  case "$1" in
    --stdout) MODE="stdout"; shift;;
    --check)  MODE="check";  shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[ -d "$SKILLS_DIR" ] || { echo "error: no skills dir at $SKILLS_DIR" >&2; exit 1; }

# --- one TSV record (name<TAB>cell<TAB>tags) per skill, sorted by name -----------
gen_rows() {
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    awk '
      function stripq(s){ if (s ~ /^".*"$/) { sub(/^"/,"",s); sub(/"$/,"",s) } return s }
      function first(s,   p){ p=index(s,". "); return (p>0)? substr(s,1,p-1) : s }
      function esc(s){ gsub(/\|/,"\\|",s); return s }
      NR==1 && $0=="---" { infm=1; next }
      infm && $0=="---"  { exit }
      infm {
        # a top-level key line (no leading whitespace)
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) {
          k=$0; sub(/:.*/,"",k)
          v=$0; sub(/^[^:]*:[ \t]*/,"",v)
          if (v ~ /^[|>][-+0-9]*[ \t]*$/) { cur=k; fm[k]=""; next }   # block scalar opener
          cur=""; fm[k]=stripq(v); next
        }
        # a continuation line of the current block scalar
        if (cur!="" && $0 ~ /^[ \t]/) {
          l=$0; sub(/^[ \t]+/,"",l); sub(/[ \t]+$/,"",l)
          fm[cur]=(fm[cur]=="")? l : fm[cur]" "l; next
        }
        cur=""
      }
      END {
        name=fm["name"]; if (name=="") exit
        cell=fm["summary"]; if (cell=="") cell=first(fm["description"])
        tags=fm["tags"]; gsub(/[][]/,"",tags); gsub(/,/," ",tags)
        printf "%s\t%s\t%s\n", name, esc(cell), tags
      }
    ' "$f"
  done | LC_ALL=C sort
}

ROWS="$(gen_rows)"   # TSV: name <TAB> cell <TAB> space-separated tags, sorted by name
[ -n "$ROWS" ] || { echo "error: no skills parsed from $SKILLS_DIR" >&2; exit 1; }

# Group the table by domain tag (in allowed-tags.txt order). Each skill carries exactly
# one domain; any skill lacking a known domain lands in an "(untagged)" bucket so nothing
# is ever dropped silently.
ALLOWED_FILE="$REPO_ROOT/bin/allowed-tags.txt"
[ -f "$ALLOWED_FILE" ] || { echo "error: no allowed-tags.txt at $ALLOWED_FILE" >&2; exit 1; }
DOMAINS="$(awk '$2=="domain"{printf "%s ",$1}' "$ALLOWED_FILE")"   # space-separated
TAB="$(printf '\t')"

print_rows() {   # stdin: TSV records -> markdown table rows
  while IFS="$TAB" read -r n cell tags; do
    [ -n "$n" ] || continue
    printf '| [`%s`](skills/%s/SKILL.md) | %s |\n' "$n" "$n" "$cell"
  done
}

build_block() {
  for d in $DOMAINS; do
    section="$(printf '%s\n' "$ROWS" | awk -F"$TAB" -v d="$d" '{m=split($3,t," "); for(i=1;i<=m;i++) if(t[i]==d){print;next}}')"
    [ -n "$section" ] || continue
    printf '### %s\n\n| Skill | What it does |\n|-------|--------------|\n' "$d"
    printf '%s\n' "$section" | print_rows
    printf '\n'
  done
  leftover="$(printf '%s\n' "$ROWS" | awk -F"$TAB" -v doms="$DOMAINS" '
    BEGIN{n=split(doms,D," "); for(i=1;i<=n;i++) dom[D[i]]=1}
    {has=0; m=split($3,t," "); for(i=1;i<=m;i++) if(t[i] in dom) has=1; if(!has) print}')"
  if [ -n "$leftover" ]; then
    printf '### (untagged)\n\n| Skill | What it does |\n|-------|--------------|\n'
    printf '%s\n' "$leftover" | print_rows
    printf '\n'
  fi
}

BLOCK="$(build_block)"
[ -n "$BLOCK" ] || { echo "error: no skills parsed from $SKILLS_DIR" >&2; exit 1; }

if [ "$MODE" = "stdout" ]; then
  printf '%s\n' "$BLOCK"
  exit 0
fi

[ -f "$README" ] || { echo "error: no README at $README" >&2; exit 1; }
grep -q '<!-- skills:start -->' "$README" && grep -q '<!-- skills:end -->' "$README" || {
  echo "error: $README is missing the <!-- skills:start --> / <!-- skills:end --> sentinels" >&2
  exit 1
}

# splice BLOCK between the sentinels, leaving the rest of README.md untouched.
# The block goes via a temp file — awk -v mangles embedded newlines/backslashes.
splice() {
  local bf; bf="$(mktemp)"; printf '%s\n' "$BLOCK" > "$bf"
  awk -v bf="$bf" '
    /<!-- skills:start -->/ { print; while ((getline l < bf) > 0) print l; close(bf); skip=1; next }
    /<!-- skills:end -->/   { skip=0 }
    !skip { print }
  ' "$README"
  rm -f "$bf"
}

NEW="$(splice)"

if [ "$MODE" = "check" ]; then
  if [ "$NEW" = "$(cat "$README")" ]; then
    echo "ok: README skills table is up to date"
    exit 0
  fi
  echo "drift: README skills table is stale — run bin/gen-readme-skills.sh" >&2
  exit 1
fi

printf '%s\n' "$NEW" > "$README"
echo "updated README skills table ($(printf '%s\n' "$ROWS" | wc -l | tr -d ' ') skills)"
