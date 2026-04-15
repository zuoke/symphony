#!/bin/sh
set -eu

trace_file="${SYMPHONY_DEMO_TRACE_FILE:-}"
proof_file="DEMO_PROOF.md"
proof_text="${SYMPHONY_DEMO_PROOF_TEXT:-# Symphony Demo Proof

issue=DEMO-1
status=completed
source=fake-codex-app-server
}"
sleep_secs="${SYMPHONY_DEMO_SLEEP_SECS:-1}"

trace() {
  if [ -n "$trace_file" ]; then
    printf '%s\n' "$1" >> "$trace_file"
  fi
}

emit() {
  printf '%s\n' "$1"
  trace "OUT:$1"
}

count=0

while IFS= read -r line; do
  count=$((count + 1))
  trace "IN:$line"

  case "$count" in
    1)
      emit '{"id":1,"result":{}}'
      ;;
    2)
      ;;
    3)
      emit '{"id":2,"result":{"thread":{"id":"demo-thread-1"}}}'
      ;;
    4)
      printf '%s' "$proof_text" > "$proof_file"
      emit '{"id":3,"result":{"turn":{"id":"demo-turn-1"}}}'
      emit '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"inputTokens":42,"outputTokens":7,"totalTokens":49}}}}'
      emit '{"method":"turn/status","params":{"message":"demo proof written"}}'
      sleep "$sleep_secs"
      emit '{"method":"turn/completed","params":{"usage":{"input_tokens":42,"output_tokens":7,"total_tokens":49}}}'
      exit 0
      ;;
    *)
      ;;
  esac
done
