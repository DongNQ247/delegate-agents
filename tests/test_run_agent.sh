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
  AGENTS_LOG="$dir/status.jsonl" bash "$root/scripts/run-agent.sh" \
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
  bash "$root/scripts/run-agent.sh" claude test-model - "$dir" claude-case - "test prompt"
grep -q '"routed_from": "claude"' "$dir/status.jsonl"
grep -q '"route_reason": "5h at 88%"' "$dir/status.jsonl"

# WAVE adds a wave field to the start event; unset or empty omits it.
dir="$tmp/wave"
mkdir -p "$dir"
AGENTS_LOG="$dir/status.jsonl" WAVE=2 bash "$root/scripts/run-agent.sh" claude test-model - "$dir" wave-case - "test prompt"
AGENTS_LOG="$dir/status.jsonl" WAVE= bash "$root/scripts/run-agent.sh" claude test-model - "$dir" nowave-case - "test prompt"
python3 - "$dir/status.jsonl" <<'PY'
import json, sys
starts = {e["id"]: e for e in map(json.loads, open(sys.argv[1])) if e.get("status") == "running"}
assert starts["wave-case"]["wave"] == "2", starts
assert "wave" not in starts["nowave-case"], starts
PY

# Agent artifacts belong beside the dashboard log, even when the worker runs elsewhere.
agents="$tmp/separate/.agents"
dir="$tmp/separate/worker"
mkdir -p "$agents" "$dir"
AGENTS_LOG="$agents/status.jsonl" ROUTED_FROM=claude ROUTE_REASON="5h at 88%" \
  bash "$root/scripts/run-agent.sh" claude test-model - "$dir" claude-separate - "test prompt"
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
  bash "$root/scripts/run-agent.sh" agy test-model - "$dir" agy-case - "test prompt"
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
  bash "$root/scripts/run-agent.sh" agy test-model - "$dir" normalizer-case - "test prompt" || true
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
(cd "$tmp/relative" && AGENTS_LOG=logs/status.jsonl bash "$root/scripts/run-agent.sh" codex test-model - worker relative-log - "test prompt")
test -f "$tmp/relative/logs/relative-log.events.jsonl"
grep -q '"status": "done"' "$tmp/relative/logs/status.jsonl"

# Whitespace-only prompt is rejected before status output.
dir="$tmp/empty-prompt"; mkdir -p "$dir"
set +e
AGENTS_LOG="$dir/status.jsonl" bash "$root/scripts/run-agent.sh" codex test-model - "$dir" empty - '   ' 2>"$dir/stderr"
code=$?
set -e
test "$code" -eq 2; grep -q usage "$dir/stderr"; test ! -e "$dir/status.jsonl"

# Unsafe id/parent are rejected before anything is written.
dir="$tmp/badid/.agents"; mkdir -p "$dir"
for args in "../x -" ".hidden -" "ok ../p"; do
  set -- $args
  set +e
  AGENTS_LOG="$dir/status.jsonl" bash "$root/scripts/run-agent.sh" codex test-model - "$tmp/badid" "$1" "$2" "p" 2>"$tmp/badid/stderr"
  code=$?
  set -e
  test "$code" -eq 2; grep -q usage "$tmp/badid/stderr"
done
test ! -e "$dir/status.jsonl"; test ! -e "$tmp/badid/x.out"; test -z "$(ls -A "$dir")"

# Timeout kills the worker's whole process group, grandchildren included.
dir="$tmp/grandchild"; mkdir -p "$dir"
set +e
FAKE_MODE=grandchild FAKE_PIDFILE="$dir/gc.pid" TIMEOUT=1 AGENTS_LOG="$dir/status.jsonl" \
  timeout 60 bash "$root/scripts/run-agent.sh" claude test-model - "$dir" gc - "p" >/dev/null 2>&1
code=$?
set -e
test "$code" -eq 124
grep -q '"status": "timeout"' "$dir/status.jsonl"
gc=$(cat "$dir/gc.pid")
for _ in $(seq 20); do kill -0 "$gc" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$gc" 2>/dev/null; then kill "$gc"; echo "FAIL: grandchild $gc survived timeout" >&2; exit 1; fi

echo PASS
