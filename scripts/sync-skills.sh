#!/bin/bash
# sync-skills.sh — give CCB the same skills your agent has, in CCB's SKILL.md
# format. CCB discovers skills from $CLAUDE_CONFIG_DIR/skills/<name>/SKILL.md.
# Your viz skills are flat ~/.claude/skills/<name>.md descriptors (CLAUDE.md-
# driven). This converts each into a CCB skill dir with frontmatter.
#
#   ./sync-skills.sh <src_skills_dir> <ccb_config_dir>
# e.g.  ./sync-skills.sh /export_home/<user>/.claude/skills /home/<user>/.ccb-home
set -euo pipefail
SRC="${1:?usage: sync-skills.sh <src_skills_dir> <ccb_config_dir>}"
CCB_HOME="${2:?usage: sync-skills.sh <src_skills_dir> <ccb_config_dir>}"
DST="$CCB_HOME/skills"
mkdir -p "$DST"

n=0
for f in "$SRC"/*.md; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .md)"
  # first non-heading, non-empty line -> one-line description
  desc="$(grep -m1 -vE '^\s*#|^\s*$' "$f" | sed 's/\*\*//g; s/[`]//g' | cut -c1-200)"
  [ -z "$desc" ] && desc="$name skill"
  mkdir -p "$DST/$name"
  { printf -- '---\nname: %s\ndescription: %s\n---\n\n' "$name" "$desc"; cat "$f"; } > "$DST/$name/SKILL.md"
  n=$((n+1))
done
echo "Synced $n skills into $DST"
