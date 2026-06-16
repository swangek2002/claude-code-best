#!/bin/bash
# install.sh — install the CCB (Claude Code Best) agent + browser chat box into
# an ACMLab viz deployment, wired to DeepSeek v4 pro.
#
# It is SAFE: it copies files and PRINTS the two lines you add to your own
# server.py / index.html — it never edits your files automatically (your
# versions differ). Re-runnable.
#
# Usage:
#   ./install.sh \
#       --project-dir   /path/to/your/visualization \
#       --keyfile       /path/to/.deepseek_key      \
#       [--ccb-dir      /path/to/claude-code-best]  \
#       [--ccb-home     ~/.ccb-home]                \
#       [--opencode     http://127.0.0.1:4097]      \
#       [--skills-src   ~/.claude/skills]
#
# Prereqs: bun >=1.3.11 (https://bun.sh), python3 with flask+tornado (your viz
# server already has them), git, a DeepSeek API key.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_DIR=""; KEYFILE=""; CCB_DIR=""; CCB_HOME="$HOME/.ccb-home"
OPENCODE="http://127.0.0.1:4097"; SKILLS_SRC=""
CCB_REPO="${CCB_REPO:-https://github.com/claude-code-best/claude-code}"
while [ $# -gt 0 ]; do case "$1" in
  --project-dir) PROJECT_DIR="$2"; shift 2;;
  --keyfile) KEYFILE="$2"; shift 2;;
  --ccb-dir) CCB_DIR="$2"; shift 2;;
  --ccb-home) CCB_HOME="$2"; shift 2;;
  --opencode) OPENCODE="$2"; shift 2;;
  --skills-src) SKILLS_SRC="$2"; shift 2;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

[ -n "$PROJECT_DIR" ] || { echo "ERROR: --project-dir is required (your viz repo with server.py + index.html)"; exit 2; }
[ -f "$PROJECT_DIR/server.py" ] || { echo "ERROR: $PROJECT_DIR/server.py not found"; exit 2; }
command -v bun >/dev/null || { echo "ERROR: bun not found. Install: curl -fsSL https://bun.sh/install | bash"; exit 2; }
[ -n "$KEYFILE" ] && [ -f "$KEYFILE" ] || { echo "ERROR: --keyfile must point to an existing file containing your DeepSeek API key"; exit 2; }
chmod 600 "$KEYFILE" || true
CCB_DIR="${CCB_DIR:-$PROJECT_DIR/claude-code-best}"

echo "==> 1/6  Clone / locate CCB at $CCB_DIR"
if [ ! -d "$CCB_DIR/.git" ]; then git clone --depth 1 "$CCB_REPO" "$CCB_DIR"; else echo "    (already cloned)"; fi

echo "==> 2/6  Apply the DeepSeek converter fix (thinking-only message → 400 guard)"
( cd "$CCB_DIR" && git apply --check "$HERE/patches/openaiConvertMessages.patch" 2>/dev/null \
    && git apply "$HERE/patches/openaiConvertMessages.patch" && echo "    patch applied" \
    || echo "    patch already applied or upstream changed — verify openaiConvertMessages.ts handles content:'' for thinking-only turns" )

echo "==> 3/6  Build CCB (bun install + vite split build) — a few minutes"
( cd "$CCB_DIR" && bun install && bun run build:vite )
[ -f "$CCB_DIR/dist/cli.js" ] || { echo "ERROR: build produced no dist/cli.js"; exit 1; }

echo "==> 4/6  Install the launcher → $PROJECT_DIR/scripts/ccb-deepseek.sh"
mkdir -p "$PROJECT_DIR/scripts" "$CCB_HOME"
sed -e "s|__CCB_DIR__|$CCB_DIR|" -e "s|__KEYFILE__|$KEYFILE|" -e "s|__CCB_HOME__|$CCB_HOME|" \
    "$HERE/scripts/ccb-deepseek.sh" > "$PROJECT_DIR/scripts/ccb-deepseek.sh"
chmod +x "$PROJECT_DIR/scripts/ccb-deepseek.sh"
echo "    smoke test:"; ( cd /tmp && OPENCODE_BASE="$OPENCODE" "$PROJECT_DIR/scripts/ccb-deepseek.sh" -p "Reply with exactly: CCB-OK" 2>/dev/null | tail -1 )

echo "==> 5/6  Sync skills into CCB (so it can run your skills)"
if [ -n "$SKILLS_SRC" ] && [ -d "$SKILLS_SRC" ]; then
  bash "$HERE/scripts/sync-skills.sh" "$SKILLS_SRC" "$CCB_HOME"
else
  echo "    (skipped — pass --skills-src to convert your ~/.claude/skills/*.md into CCB skills)"
fi

echo "==> 6/6  Install backend + frontend assets"
cp "$HERE/backend/ccb_chat.py" "$PROJECT_DIR/ccb_chat.py"
cp "$HERE/frontend/ccb-chat-widget.js" "$PROJECT_DIR/ccb-chat-widget.js"
cat <<EOF

────────────────────────────────────────────────────────────────────────────
DONE. Two small wiring steps remain (your files differ, so do them by hand):

 (A) BACKEND — in $PROJECT_DIR/server.py, after \`app = Flask(__name__)\` and
     PROJECT_DIR are defined, add:

         from ccb_chat import register_chat_routes
         register_chat_routes(app, PROJECT_DIR)

     Make sure your server serves the project dir statics (so /ccb-chat-widget.js
     is reachable), or add a route returning ccb-chat-widget.js.

 (B) FRONTEND — in $PROJECT_DIR/index.html, just before </body>, add:

         <script src="/ccb-chat-widget.js"></script>

 Then restart your viz server. Open the page → a blue "💬 AGENT" tab on the
 left → toggle between "Original · opencode" and "Claude Code Best".

 Env knobs (optional): OPENCODE_BASE=$OPENCODE  OPENAI_BASE_URL  CHAT_TIMEOUT_S
────────────────────────────────────────────────────────────────────────────
EOF
