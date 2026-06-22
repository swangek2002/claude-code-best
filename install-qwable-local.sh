#!/bin/bash
# install-qwable-local.sh — Version 2 (your OWN machine): install a private
# up-to-date ollama (no sudo), pull the Qwable model size(s), and start the
# daemon so your CCB agent can use Qwable locally instead of the paid DeepSeek API.
#
# After this finishes, point CCB at it (see README "Switching models"):
#   export QWABLE_OLLAMA_URL=http://127.0.0.1:11500/v1
#   CCB_PROFILE=qwable-small ./scripts/ccb-agent.sh -p "hello"
#
# Usage:
#   ./install-qwable-local.sh                       # pulls small + medium (fit a 24GB GPU)
#   ./install-qwable-local.sh --sizes "small medium large"
#   ./install-qwable-local.sh --port 11500 --models-dir ~/.ollama/models
#
# Linux/amd64 + NVIDIA. macOS users: install the official ollama app, then just
# `ollama pull` the tags below and skip the download step.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SIZES="small medium"
PORT=11500
MODELS_DIR="$HOME/.ollama/models"
PREFIX="$HOME/qwable-ollama"
OLLAMA_VER="0.30.10"
while [ $# -gt 0 ]; do case "$1" in
  --sizes) SIZES="$2"; shift 2;;
  --port) PORT="$2"; shift 2;;
  --models-dir) MODELS_DIR="$2"; shift 2;;
  --prefix) PREFIX="$2"; shift 2;;
  --ollama-version) OLLAMA_VER="$2"; shift 2;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done

declare -A TAG=(
  [large]="hf.co/Mia-AiLab/Qwable-3.6-35b:Q8_0"
  [medium]="hf.co/Mia-AiLab/Qwable-3.6-35b:Q4_K_M"
  [small]="hf.co/Mia-AiLab/Qwable-3.6-27b:Q4_K_M"
)
declare -A VRAM=( [large]="~37GB (needs 40GB+ VRAM, e.g. 2x24GB)" [medium]="~21GB (fits 24GB)" [small]="~16GB (fits 24GB)" )

echo "==> 1/4  Ensure an up-to-date ollama (>= 0.17 for qwen35moe)"
ver_ok() { local v; v="$("$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"; [ -n "$v" ] && awk -v v="$v" 'BEGIN{split(v,a,".");exit !(a[1]>0||a[2]>=17)}'; }
BIN=""
if command -v ollama >/dev/null && ver_ok "$(command -v ollama)"; then
  BIN="$(command -v ollama)"; echo "    using system ollama: $BIN ($("$BIN" --version|tail -1))"
elif [ -x "$PREFIX/bin/ollama" ] && ver_ok "$PREFIX/bin/ollama"; then
  BIN="$PREFIX/bin/ollama"; echo "    using existing private ollama: $BIN"
else
  echo "    downloading ollama v$OLLAMA_VER (CUDA bundle) to $PREFIX …"
  command -v zstd >/dev/null || { echo "ERROR: 'zstd' is required to unpack ollama. Install it (apt-get install zstd / brew install zstd) and re-run."; exit 1; }
  mkdir -p "$PREFIX"
  url="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VER}/ollama-linux-amd64.tar.zst"
  curl -L --retry 3 -o "$PREFIX/ollama.tar.zst" "$url"
  tar --zstd -xf "$PREFIX/ollama.tar.zst" -C "$PREFIX" && rm -f "$PREFIX/ollama.tar.zst"
  BIN="$PREFIX/bin/ollama"
  [ -x "$BIN" ] || { echo "ERROR: ollama not found at $BIN after unpack"; exit 1; }
  echo "    installed: $BIN ($("$BIN" --version|tail -1))"
fi

echo "==> 2/4  Start the private ollama daemon on :$PORT"
OLLAMA_BIN="$BIN" QWABLE_PORT="$PORT" QWABLE_MODELS_DIR="$MODELS_DIR" bash "$HERE/scripts/qwable-serve.sh"

echo "==> 3/4  Pull Qwable model size(s): $SIZES"
for s in $SIZES; do
  t="${TAG[$s]:-}"; [ -n "$t" ] || { echo "    skip unknown size '$s'"; continue; }
  echo "    --- $s : $t   ${VRAM[$s]} ---"
  OLLAMA_HOST="127.0.0.1:$PORT" "$BIN" pull "$t"
done

echo "==> 4/4  Done. Connect CCB to your local Qwable:"
cat <<EOF

────────────────────────────────────────────────────────────────────────────
  export QWABLE_OLLAMA_URL=http://127.0.0.1:${PORT}/v1
  CCB_PROFILE=qwable-small  ./scripts/ccb-agent.sh -p "Reply with exactly: QWABLE-OK"

  Pulled sizes: ${SIZES}
    small  -> ${TAG[small]}
    medium -> ${TAG[medium]}
    large  -> ${TAG[large]}   (only if you pulled it)

  To expose these in the browser chat widget, set in your viz server env:
    QWABLE_OLLAMA_URL=http://127.0.0.1:${PORT}/v1
  and restart the server. The widget's model dropdown will show the sizes
  whose models are present.
  Re-run the daemon after a reboot:  ./scripts/qwable-serve.sh
────────────────────────────────────────────────────────────────────────────
EOF
