#!/usr/bin/env bash
# Poll ace for K80 GPU + Ollama37 readiness (run via: ssh ace 'bash -s' < scripts/ace-poll-k80-ready.sh)
set -euo pipefail
MAX=20
INTERVAL=60
for i in $(seq 1 "$MAX"); do
  echo "=== Poll $i/$MAX $(date -u +%H:%M:%S) ==="
  GPU=$(nvidia-smi -L 2>&1 || true)
  OLLAMA=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:11434/api/tags 2>/dev/null || echo 000)
  echo "GPU: $GPU"
  echo "Ollama HTTP: $OLLAMA"
  GPU_OK=0
  OLLAMA_OK=0
  echo "$GPU" | grep -qiE 'K80|Tesla' && GPU_OK=1
  [ "$OLLAMA" = "200" ] && OLLAMA_OK=1
  if [ "$GPU_OK" = "1" ] && [ "$OLLAMA_OK" = "1" ]; then
    echo "READY"
    exit 0
  fi
  [ "$i" -lt "$MAX" ] && sleep "$INTERVAL"
done
echo "NOT_READY"
exit 1
