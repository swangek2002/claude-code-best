#!/bin/bash
# qwable-serve.sh — start (idempotently) a private ollama daemon tuned to serve
# the Qwable GGUF models for CCB. Safe to run repeatedly; if the daemon is
# already up on the port it does nothing.
#
# Why a private daemon (not the system one): the Qwable models use the brand-new
# `qwen35moe`/`qwen35` architectures, which need ollama >= 0.17.1. Many boxes
# still ship an older system ollama. This runs YOUR own up-to-date ollama on a
# separate port, as you, no sudo, without touching the system service.
#
# Env knobs (all optional):
#   OLLAMA_BIN          path to an ollama >= 0.30 binary (default: auto-detect)
#   QWABLE_PORT         port to serve on            (default: 11500)
#   QWABLE_MODELS_DIR   model store                 (default: $HOME/.ollama/models)
set -uo pipefail

QWABLE_PORT="${QWABLE_PORT:-11500}"
QWABLE_MODELS_DIR="${QWABLE_MODELS_DIR:-$HOME/.ollama/models}"
LOG="${QWABLE_LOG:-$HOME/.ollama/qwable-serve.log}"

# Locate an ollama binary >= 0.17 (qwen35moe support). Prefer an explicit
# OLLAMA_BIN, then a local private install, then whatever is on PATH.
pick_bin() {
  if [ -n "${OLLAMA_BIN:-}" ] && [ -x "$OLLAMA_BIN" ]; then echo "$OLLAMA_BIN"; return; fi
  for c in "$HOME/qwable-ollama/bin/ollama" /ram/USERS/swangek/ollama-0.30.10/bin/ollama "$(command -v ollama 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  echo ""
}
BIN="$(pick_bin)"
[ -n "$BIN" ] || { echo "qwable-serve: no ollama binary found. Run install-qwable-local.sh first." >&2; exit 2; }

# Already serving?
if curl -s -m 3 "http://127.0.0.1:${QWABLE_PORT}/api/version" >/dev/null 2>&1; then
  echo "qwable-serve: already up on :${QWABLE_PORT} ($("$BIN" --version 2>/dev/null | tail -1))"
  exit 0
fi

mkdir -p "$QWABLE_MODELS_DIR" "$(dirname "$LOG")"
echo "qwable-serve: starting $BIN on :${QWABLE_PORT}  (models: $QWABLE_MODELS_DIR)"
OLLAMA_HOST="127.0.0.1:${QWABLE_PORT}" \
OLLAMA_MODELS="$QWABLE_MODELS_DIR" \
OLLAMA_LOAD_TIMEOUT="${OLLAMA_LOAD_TIMEOUT:-20m}" \
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-24h}" \
  nohup "$BIN" serve >> "$LOG" 2>&1 &
echo "qwable-serve: pid $! — waiting for it to come up…"
for i in $(seq 1 20); do
  sleep 1
  curl -s -m 3 "http://127.0.0.1:${QWABLE_PORT}/api/version" >/dev/null 2>&1 && { echo "qwable-serve: up on :${QWABLE_PORT}"; exit 0; }
done
echo "qwable-serve: did not come up in 20s — check $LOG" >&2
exit 1
