#!/bin/bash
# ccb-deepseek.sh — run CCB (claude-code-best, the open-source Claude Code
# rebuild) against DeepSeek v4, mirroring your opencode model config.
#
#   ./ccb-deepseek.sh -p "your prompt"          # headless one-shot (JSON: add --output-format json)
#   ./ccb-deepseek.sh                            # interactive REPL
#   CCB_MODEL=deepseek-v4-flash ./ccb-deepseek.sh -p "..."
#
# Edit the three CONFIG paths below (install.sh fills them in automatically).
# The API key lives ONLY in a 0600 keyfile — never inline here.
set -uo pipefail

# ─── CONFIG (install.sh substitutes these) ───────────────────────────────
CCB_DIR="${CCB_DIR:-__CCB_DIR__}"                 # the claude-code-best clone (built: has dist/cli.js)
KEYFILE="${DEEPSEEK_KEYFILE:-__KEYFILE__}"         # 0600 file containing the DeepSeek API key
CCB_HOME="${CCB_CONFIG_DIR:-__CCB_HOME__}"         # isolated CLAUDE_CONFIG_DIR (skills + state live here)
# ─────────────────────────────────────────────────────────────────────────

export PATH="$HOME/.bun/bin:$PATH"
export CLAUDE_CODE_USE_OPENAI=1
export OPENAI_API_KEY="$(cat "$KEYFILE")"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://api.deepseek.com}"
export OPENAI_MODEL="${CCB_MODEL:-deepseek-v4-pro}"
export OPENAI_SMALL_FAST_MODEL="${CCB_SMALL_MODEL:-deepseek-v4-flash}"
export CLAUDE_CONFIG_DIR="$CCB_HOME"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1

if [ -f "$CCB_DIR/dist/cli.js" ]; then
  exec bun "$CCB_DIR/dist/cli.js" "$@"        # built: runs in the real cwd, low RSS
else
  cd "$CCB_DIR" && exec bun run scripts/dev.ts "$@"   # fallback (forces cwd=projectRoot)
fi
