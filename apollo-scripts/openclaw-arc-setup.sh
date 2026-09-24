#!/usr/bin/env bash
# OpenClaw <-> Windows-Ollama (Intel Arc A770) setup for the Ubuntu VM.
#
# WHAT THIS DOES:
#   1. Finds/verifies the OpenClaw CLI (installs it via the official installer if missing).
#   2. Finds the Windows host running Ollama and verifies it's reachable + has your model.
#   3. Backs up your current OpenClaw config before touching it.
#   4. Points OpenClaw's "ollama" provider at the Windows host, tuned for a 12B model
#      on 16GB VRAM (large context, keep-alive to avoid cold reloads).
#   5. Sets ollama/<model> as your default agent model.
#   6. Runs `openclaw doctor --fix` and verifies with real inference calls.
#
# Auto-discovery: default gateway -> ".1" host convention -> full /24 port scan
# fallback for the Windows Ollama host. Confirmed working host for this VM:
# 192.168.221.1 (VMware VMnet8 NAT).

set -euo pipefail

# ---------- Config (override via env vars) ----------
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
MODEL_ID="${MODEL_ID:-gemma4}"
CONTEXT_TOKENS="${CONTEXT_TOKENS:-65536}"
KEEP_ALIVE="${KEEP_ALIVE:-30m}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
ENABLE_LOCAL_MEMORY="${ENABLE_LOCAL_MEMORY:-no}"

WIN_HOST="${1:-}"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m    ok:\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m    warn:\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m    error:\033[0m %s\n' "$1"; exit 1; }

log "Checking for the OpenClaw CLI"
OPENCLAW_CMD=""
if command -v openclaw >/dev/null 2>&1; then
  OPENCLAW_CMD="openclaw"
  ok "found on PATH: $(command -v openclaw)"
else
  warn "openclaw not found on PATH. Installing via the official installer."
  curl -fsSL https://openclaw.ai/install.sh | bash
  hash -r
  if command -v openclaw >/dev/null 2>&1; then
    OPENCLAW_CMD="openclaw"
    ok "installed: $(command -v openclaw)"
  else
    die "install finished but 'openclaw' is still not on PATH. Open a new shell and re-run."
  fi
fi
"$OPENCLAW_CMD" --version || die "openclaw CLI did not respond to --version"

log "Locating the Windows Ollama host"
CANDIDATES=()
PREFIX=""
if [ -n "$WIN_HOST" ]; then
  CANDIDATES+=("$WIN_HOST")
  ok "using host passed on the command line: $WIN_HOST"
else
  GATEWAY_IP="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  OWN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ -n "$OWN_IP" ] && PREFIX="$(echo "$OWN_IP" | cut -d. -f1-3)"
  if [ -n "${GATEWAY_IP:-}" ]; then
    CANDIDATES+=("$GATEWAY_IP")
    warn "no IP given, trying the VM's default gateway first: $GATEWAY_IP"
  fi
  if [ -n "$PREFIX" ] && [ "${PREFIX}.1" != "${GATEWAY_IP:-}" ]; then
    CANDIDATES+=("${PREFIX}.1")
  fi
fi

if [ "${#CANDIDATES[@]}" -eq 0 ] && [ -z "$PREFIX" ]; then
  die "no Windows host IP known, no default gateway, and no own IP detected. Re-run as: ./openclaw-arc-setup.sh <windows-ip>"
fi

REACHABLE_HOST=""
for host in "${CANDIDATES[@]}"; do
  printf '    trying http://%s:%s/api/tags ... ' "$host" "$OLLAMA_PORT"
  if curl -fsS --max-time 3 "http://${host}:${OLLAMA_PORT}/api/tags" >/tmp/ollama-tags.json 2>/dev/null; then
    echo "reachable"
    REACHABLE_HOST="$host"
    break
  else
    echo "unreachable"
  fi
done

if [ -z "$REACHABLE_HOST" ] && [ -n "$PREFIX" ]; then
  warn "quick candidates failed, scanning ${PREFIX}.0/24 on port ${OLLAMA_PORT} (takes ~10-20s)"
  SCAN_DIR="$(mktemp -d)"
  for ((i = 1; i <= 254; i++)); do
    ip="${PREFIX}.${i}"
    (
      if curl -fsS --max-time 1 "http://${ip}:${OLLAMA_PORT}/api/tags" 2>/dev/null | grep -q '"models"'; then
        echo "$ip" >>"$SCAN_DIR/found"
      fi
    ) &
    if ((i % 50 == 0)); then wait; fi
  done
  wait
  if [ -f "$SCAN_DIR/found" ]; then
    REACHABLE_HOST="$(head -n1 "$SCAN_DIR/found")"
    curl -fsS --max-time 3 "http://${REACHABLE_HOST}:${OLLAMA_PORT}/api/tags" >/tmp/ollama-tags.json 2>/dev/null
    ok "found Ollama via subnet scan at $REACHABLE_HOST"
  fi
  rm -rf "$SCAN_DIR"
fi

if [ -z "$REACHABLE_HOST" ]; then
  die "could not reach Ollama on any candidate host, including a full subnet scan."
fi
WIN_HOST="$REACHABLE_HOST"
ok "Windows Ollama reachable at http://${WIN_HOST}:${OLLAMA_PORT}"

log "Checking that '${MODEL_ID}' is available on the Windows Ollama"
if grep -q "\"name\":\"${MODEL_ID}" /tmp/ollama-tags.json 2>/dev/null || \
   grep -q "\"model\":\"${MODEL_ID}" /tmp/ollama-tags.json 2>/dev/null; then
  ok "model '${MODEL_ID}' found"
else
  warn "model '${MODEL_ID}' not seen in the tag list on ${WIN_HOST}."
fi
rm -f /tmp/ollama-tags.json

CONFIG_FILE="$HOME/.openclaw/openclaw.json"
if [ -f "$CONFIG_FILE" ]; then
  BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP_FILE"
  ok "backed up existing config to $BACKUP_FILE"
fi

log "Configuring the 'ollama' provider"
PROVIDER_JSON=$(cat <<EOF
{
  "baseUrl": "http://${WIN_HOST}:${OLLAMA_PORT}",
  "apiKey": "ollama-local",
  "api": "ollama",
  "timeoutSeconds": ${TIMEOUT_SECONDS},
  "models": [
    {
      "id": "${MODEL_ID}",
      "name": "${MODEL_ID}",
      "input": ["text"],
      "contextTokens": ${CONTEXT_TOKENS},
      "params": {
        "num_ctx": ${CONTEXT_TOKENS},
        "keep_alive": "${KEEP_ALIVE}"
      }
    }
  ]
}
EOF
)
"$OPENCLAW_CMD" config set models.providers.ollama "$PROVIDER_JSON" --strict-json --merge
"$OPENCLAW_CMD" config set agents.defaults.model.primary "ollama/${MODEL_ID}" --strict-json

if [ "$ENABLE_LOCAL_MEMORY" = "yes" ]; then
  MEMORY_JSON=$(cat <<EOF
{
  "search": {
    "provider": "ollama",
    "model": "nomic-embed-text",
    "remote": {
      "baseUrl": "http://${WIN_HOST}:${OLLAMA_PORT}",
      "apiKey": "ollama-local"
    }
  }
}
EOF
)
  "$OPENCLAW_CMD" config set memory "$MEMORY_JSON" --strict-json --merge
fi

log "Running 'openclaw doctor --fix'"
"$OPENCLAW_CMD" doctor --fix || warn "doctor reported issues above - review them"

log "Verifying with real inference calls"
"$OPENCLAW_CMD" infer model run --local --model "ollama/${MODEL_ID}" --prompt "Reply with exactly: pong" --json \
  || die "direct model call failed"
"$OPENCLAW_CMD" infer model run --gateway --model "ollama/${MODEL_ID}" --prompt "Reply with exactly: pong" --json \
  || warn "gateway-routed call failed - Gateway may need a restart"

"$OPENCLAW_CMD" gateway restart || warn "restart it yourself however you normally start it"

echo "Done. Windows Ollama host: http://${WIN_HOST}:${OLLAMA_PORT}, model: ollama/${MODEL_ID}"
