#!/usr/bin/env bash
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export TEST_ROOT="$root"
export PATH="$root/tests/fakebin:$PATH"
export DELEGATE_QUOTA="$tmp/quota.json"
export DELEGATE_CODEX_SESSIONS="$tmp/codex-sessions"
export TIMEOUT=5

run_worker() {
  local agent=$1 id=$2 dir=$3
  mkdir -p "$dir"
  AGENTS_LOG="$dir/status.jsonl" bash "$root/run-agent.sh" \
    "$agent" test-model - "$dir" "$id" - "test prompt"
}

dir="$tmp/codex"
run_worker codex codex-case "$dir"
python3 - "$dir/status.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
assert events[-1]["status"] == "done", events
PY
grep -q '"kind": "command"' "$dir/codex-case.events.jsonl"
test "$(cat "$dir/codex-case.out")" = "fake final"

dir="$tmp/claude"
mkdir -p "$dir"
AGENTS_LOG="$dir/status.jsonl" ROUTED_FROM=claude ROUTE_REASON="5h at 88%" \
  bash "$root/run-agent.sh" claude test-model - "$dir" claude-case - "test prompt"
grep -q '"routed_from": "claude"' "$dir/status.jsonl"
grep -q '"route_reason": "5h at 88%"' "$dir/status.jsonl"

# Agent artifacts belong beside the dashboard log, even when the worker runs elsewhere.
agents="$tmp/separate/.agents"
dir="$tmp/separate/worker"
mkdir -p "$agents" "$dir"
AGENTS_LOG="$agents/status.jsonl" ROUTED_FROM=claude ROUTE_REASON="5h at 88%" \
  bash "$root/run-agent.sh" claude test-model - "$dir" claude-separate - "test prompt"
python3 - "$agents" "$dir" <<'PY'
import json, os, sys
agents, worker = sys.argv[1:]
for name in ("claude-separate.events.jsonl", "claude-separate.raw.jsonl",
             "claude-separate.err", "claude-separate.out"):
    assert os.path.isfile(os.path.join(agents, name)), name
assert not os.listdir(worker), os.listdir(worker)
events = [json.loads(line) for line in open(os.path.join(agents, "status.jsonl"))]
assert events[-1]["status"] == "done", events
assert events[-1]["summary"].strip(), events[-1]
PY

dir="$tmp/agy"
mkdir -p "$dir"
set +e
AGENTS_LOG="$dir/status.jsonl" FAKE_EXIT=3 \
  bash "$root/run-agent.sh" agy test-model - "$dir" agy-case - "test prompt"
code=$?
set -e
test "$code" -eq 3
python3 - "$dir/status.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
assert events[-1]["status"] == "failed", events
assert events[-1]["code"] == "3", events
PY

dir="$tmp/normalizer-exit"
mkdir -p "$dir"
timeout 10 env AGENTS_LOG="$dir/status.jsonl" NORMALIZER=/bin/false \
  bash "$root/run-agent.sh" agy test-model - "$dir" normalizer-case - "test prompt" || true
test -s "$dir/status.jsonl"
python3 - "$dir/status.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
assert len(events) >= 2, events
assert events[0]["status"] == "running", events
assert events[-1]["status"] in {"done", "failed", "timeout"}, events
PY


# Relative log paths remain anchored to the caller cwd after worker cd.
mkdir -p "$tmp/relative/worker"
(cd "$tmp/relative" && AGENTS_LOG=logs/status.jsonl bash "$root/run-agent.sh" codex test-model - worker relative-log - "test prompt")
test -f "$tmp/relative/logs/relative-log.events.jsonl"
grep -q '"status": "done"' "$tmp/relative/logs/status.jsonl"

# Whitespace-only prompt is rejected before status output.
dir="$tmp/empty-prompt"; mkdir -p "$dir"
set +e
AGENTS_LOG="$dir/status.jsonl" bash "$root/run-agent.sh" codex test-model - "$dir" empty - '   ' 2>"$dir/stderr"
code=$?
set -e
test "$code" -eq 2; grep -q usage "$dir/stderr"; test ! -e "$dir/status.jsonl"

echo PASS
