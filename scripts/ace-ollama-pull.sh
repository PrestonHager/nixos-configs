#!/usr/bin/env bash
# Pull a small K80-suitable model via Ollama37 API (run on ace).
set -euo pipefail
MODEL="${1:-llama3.2:3b}"
echo "Pulling ${MODEL}..."
curl -sf -X POST http://127.0.0.1:11434/api/pull \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${MODEL}\"}"
echo
echo "=== tags ==="
curl -sf http://127.0.0.1:11434/api/tags
echo
echo "=== generate test ==="
curl -sf -X POST http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"Say hi in 3 words\",\"stream\":false}" \
  | head -c 500
echo
