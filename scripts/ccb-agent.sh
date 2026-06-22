#!/bin/bash
# ccb-agent.sh — unified CCB (claude-code-best) launcher with switchable backends.
#
# Pick the model with CCB_PROFILE (default: deepseek). Profiles:
#   deepseek         DeepSeek v4 pro   (paid API,  api.deepseek.com)        — needs keyfile
#   qwable-large     Qwable-3.6-35b Q8_0  (~37GB VRAM, best quality)        — local ollama
#   qwable-medium    Qwable-3.6-35b Q4_K_M (~21GB VRAM, same brain, faster) — local ollama
#   qwable-small     Qwable-3.6-27b Q4_K_M (~16GB VRAM, smaller & fastest)  — local ollama
#
# The qwable-* profiles talk to an ollama OpenAI-compatible endpoint. Point it
# with QWABLE_OLLAMA_URL:
#   - Version 1 (on the tesla server, model already running):  http://127.0.0.1:11500/v1
#   - Version 2 (your own machine, after install-qwable-local): http://127.0.0.1:11500/v1
#
# Usage:
#   CCB_PROFILE=qwable-medium ./ccb-agent.sh -p "your prompt"
#   ./ccb-agent.sh                                  # interactive, default profile
#
# Everything below is overridable by env so the same file works installed
# (placeholders filled by install.sh) or run straight from a checkout.
set -uo pipefail

CCB_DIR="${CCB_DIR:-__CCB_DIR__}"                       # CCB checkout with dist/cli.js
CCB_HOME="${CCB_HOME:-__CCB_HOME__}"                    # isolated CCB state dir
DEEPSEEK_KEYFILE="${DEEPSEEK_KEYFILE:-__KEYFILE__}"     # 0600 file holding the DeepSeek key
QWABLE_OLLAMA_URL="${QWABLE_OLLAMA_URL:-http://127.0.0.1:11500/v1}"
PROFILE="${CCB_PROFILE:-deepseek}"

# Model tags (override if you pulled different quants/sizes).
QWABLE_LARGE_MODEL="${QWABLE_LARGE_MODEL:-hf.co/Mia-AiLab/Qwable-3.6-35b:Q8_0}"
QWABLE_MEDIUM_MODEL="${QWABLE_MEDIUM_MODEL:-hf.co/Mia-AiLab/Qwable-3.6-35b:Q4_K_M}"
QWABLE_SMALL_MODEL="${QWABLE_SMALL_MODEL:-hf.co/Mia-AiLab/Qwable-3.6-27b:Q4_K_M}"

export PATH="$HOME/.bun/bin:$PATH"
export CLAUDE_CODE_USE_OPENAI=1
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1

case "$PROFILE" in
  deepseek)
    [ -f "$DEEPSEEK_KEYFILE" ] || { echo "ccb-agent: DeepSeek keyfile not found: $DEEPSEEK_KEYFILE" >&2; exit 2; }
    export OPENAI_BASE_URL="https://api.deepseek.com"
    export OPENAI_API_KEY="$(cat "$DEEPSEEK_KEYFILE")"
    export OPENAI_MODEL="deepseek-v4-pro"
    export OPENAI_SMALL_FAST_MODEL="deepseek-v4-flash"
    ;;
  qwable-large|qwable-medium|qwable-small)
    case "$PROFILE" in
      qwable-large)  M="$QWABLE_LARGE_MODEL";;
      qwable-medium) M="$QWABLE_MEDIUM_MODEL";;
      qwable-small)  M="$QWABLE_SMALL_MODEL";;
    esac
    export OPENAI_BASE_URL="$QWABLE_OLLAMA_URL"
    export OPENAI_API_KEY="ollama"          # ignored by ollama, but must be non-empty
    export OPENAI_MODEL="$M"
    # Use the same tag for the small/fast model so the profile works even if you
    # only pulled this one size. Set QWABLE_SMALL_MODEL to a 27b for cheaper aux calls.
    export OPENAI_SMALL_FAST_MODEL="$M"
    ;;
  *)
    echo "ccb-agent: unknown CCB_PROFILE='$PROFILE' (deepseek|qwable-large|qwable-medium|qwable-small)" >&2
    exit 2
    ;;
esac

# One shared CCB home across profiles so sessions resume across model switches.
export CLAUDE_CONFIG_DIR="$CCB_HOME"
mkdir -p "$CLAUDE_CONFIG_DIR"

if [ -f "$CCB_DIR/dist/cli.js" ]; then
  exec bun "$CCB_DIR/dist/cli.js" "$@"
else
  cd "$CCB_DIR" && exec bun run scripts/dev.ts "$@"
fi
