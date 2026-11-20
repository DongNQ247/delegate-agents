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
grep -q '"kind": "command"' "$dir/codex-case/events.jsonl"
test "$(cat "$dir/codex-case/out")" = "fake final"

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
for name in ("claude-separate/events.jsonl", "claude-separate/raw.jsonl",
             "claude-separate/err", "claude-separate/out"):
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
test -f "$tmp/relative/logs/relative-log/events.jsonl"
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
test ! -e "$dir/status.jsonl"; test ! -e "$tmp/badid/x/out"; test -z "$(ls -A "$dir")"

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

# RESUME continues the earlier worker's session with the same agent.
dir="$tmp/resume"; mkdir -p "$dir"
for a in codex claude agy; do run_worker "$a" "$a-first" "$dir" >/dev/null; done
for a in codex claude agy; do
  AGENTS_LOG="$dir/status.jsonl" RESUME="$a-first" FAKE_ARGV="$dir/$a.argv" CTX_WINDOW=1000000 \
    bash "$root/scripts/run-agent.sh" "$a" test-model - "$dir" "$a-fix1" - "fix it" >/dev/null
done
grep -q '^exec resume 01a1f2e8-3f38-7870-859a-846c5929cfb3 .*-c sandbox_mode=workspace-write' "$dir/codex.argv"
grep -q -- '--resume 34cb7732-ccc0-4988-a249-147c0ddeb20a' "$dir/claude.argv"
grep -q -- '--conversation 97635adb-8352-40cb-8f56-f82c71ce1f59' "$dir/agy.argv"
AGENTS_LOG="$dir/status.jsonl" RESUME=codex-first MODE=ro FAKE_ARGV="$dir/ro.argv" CTX_WINDOW=1000000 \
  bash "$root/scripts/run-agent.sh" codex test-model - "$dir" codex-ro - "review" >/dev/null
grep -q 'sandbox_mode=read-only' "$dir/ro.argv"
python3 - "$dir/status.jsonl" <<'PY'
import json, sys
starts = {e["id"]: e for e in map(json.loads, open(sys.argv[1])) if e.get("status") == "running"}
assert starts["claude-fix1"]["resumed_from"] == "claude-first", starts
assert "resumed_from" not in starts["claude-first"], starts
PY
lines=$(wc -l < "$dir/status.jsonl")
for args in "nosuch claude" "claude-first codex"; do
  set -- $args
  set +e
  AGENTS_LOG="$dir/status.jsonl" RESUME="$1" FAKE_ARGV="$dir/bad.argv" \
    bash "$root/scripts/run-agent.sh" "$2" test-model - "$dir" bad - "p" 2>/dev/null
  code=$?
  set -e
  test "$code" -eq 2
done
test "$(wc -l < "$dir/status.jsonl")" -eq "$lines"; test ! -e "$dir/bad.argv"

# RESUME is refused at >= 60% of the model window (exit 3, status rotate, CLI not launched).
dir="$tmp/ctx"; mkdir -p "$dir"
ctx_resume() {  # id env... -> sets code; stderr in $dir/err
  local id=$1; shift
  set +e
  env AGENTS_LOG="$dir/status.jsonl" RESUME=c1 FAKE_ARGV="$dir/$id.argv" "$@" \
    bash "$root/scripts/run-agent.sh" claude "${MODEL:-haiku}" - "$dir" "$id" - "next" >/dev/null 2>"$dir/err"
  code=$?
  set -e
}
# a running worker whose context crosses the limit is never stopped: only RESUME checks .ctx
AGENTS_LOG="$dir/status.jsonl" CTX_LIMIT=0.01 bash "$root/scripts/run-agent.sh" claude haiku - "$dir" c1 - "p" >/dev/null
test "$(tail -1 "$dir/status.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = done
test "$(cat "$dir/c1/ctx")" -eq 27795
ctx_resume ok; test "$code" -eq 0; test -s "$dir/ok.argv"  # alias haiku: 27795/200000 = 13%
echo 130000 > "$dir/c1/ctx"
ctx_resume hot; test "$code" -eq 3; test ! -e "$dir/hot.argv"
grep -q 'context 65% ≥ 60%: rotate' "$dir/err"
tail -1 "$dir/status.jsonl" | python3 -c '
import json, sys
e = json.load(sys.stdin)
assert e["id"] == "hot" and e["status"] == "rotate" and e["code"] == "3", e'
ctx_resume ho HANDOFF=1; test "$code" -eq 0; test -s "$dir/ho.argv"
ctx_resume ho0 HANDOFF=0; test "$code" -eq 3
rm "$dir/c1/ctx"
ctx_resume noctx CTX_WINDOW=1000000; test "$code" -eq 3; grep -q 'no context size' "$dir/err"; test ! -e "$dir/noctx.argv"
echo 1000 > "$dir/c1/ctx"
MODEL=test-model ctx_resume unk; test "$code" -eq 3; grep -q 'unknown window: hire fresh' "$dir/err"
MODEL=claude-opus-5-5 ctx_resume full; test "$code" -eq 0

# stop cancels a running worker and cleans up its marker files.
dir="$tmp/stop"; mkdir -p "$dir"
FAKE_MODE=sleep FAKE_PIDFILE="$dir/w.pid" TIMEOUT=60 AGENTS_LOG="$dir/status.jsonl" \
  bash "$root/scripts/run-agent.sh" claude test-model - "$dir" st - "p" >/dev/null 2>&1 &
bg=$!
for _ in $(seq 50); do [ -s "$dir/w.pid" ] && [ -s "$dir/st/pgid" ] && break; sleep 0.1; done
AGENTS_LOG="$dir/status.jsonl" bash "$root/scripts/run-agent.sh" stop st
wait "$bg" || true
python3 - "$dir/status.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
assert events[-1]["status"] == "cancelled", events
PY
! kill -0 "$(cat "$dir/w.pid")" 2>/dev/null
test ! -e "$dir/st/pgid"; test ! -e "$dir/st/cancelled"
lines=$(wc -l < "$dir/status.jsonl")
for target in nosuch st; do  # unknown, then already finished
  set +e
  AGENTS_LOG="$dir/status.jsonl" bash "$root/scripts/run-agent.sh" stop "$target" 2>/dev/null
  code=$?
  set -e
  test "$code" -eq 1
done
test "$(wc -l < "$dir/status.jsonl")" -eq "$lines"

# A stop marker left after a clean exit does not turn done into cancelled.
dir="$tmp/stop-race"; mkdir -p "$dir"
FAKE_MODE=race FAKE_MARKER="$dir/race/cancelled" AGENTS_LOG="$dir/status.jsonl" bash "$root/scripts/run-agent.sh" claude test-model - "$dir" race - "p" >/dev/null
grep -q '"status": "done"' "$dir/status.jsonl"; test ! -e "$dir/race/cancelled"

# Retry: a verified transient error resumes the session; anything else fails as before.
retry_case() {  # name agent mode fixture [env...] -> runs a worker, leaves $dir with status/argv
  local name=$1 a=$2 mode=$3 fx=$4; shift 4
  dir="$tmp/retry-$name"; mkdir -p "$dir"
  set +e
  env "$@" RETRY_WAIT="0 0" FAKE_MODE="$mode" FAKE_FIXTURE="$root/tests/fixtures/$fx" FAKE_STATE="$dir/state" \
    FAKE_ARGV="$dir/argv" AGENTS_LOG="$dir/status.jsonl" \
    bash "$root/scripts/run-agent.sh" "$a" test-model - "$dir" "$name" - "do it" >/dev/null 2>&1
  code=$?
  set -e
}
check_status() {  # final-status retries
  python3 - "$dir/status.jsonl" "$1" "$2" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
assert events[-1]["status"] == sys.argv[2], events
assert [e["retry"] for e in events if "retry" in e] == [str(i) for i in range(1, int(sys.argv[3]) + 1)], events
PY
}
for fx in transient-codex.txt transient-codex-capacity.txt; do
  retry_case codex-once codex fail-once "$fx"
  test "$code" -eq 0; check_status done 1
  sed -n 2p "$dir/argv" | grep -q '^exec resume 01a1f2e8-3f38-7870-859a-846c5929cfb3 .*Continue the task. The previous attempt was interrupted by: '
  rm -rf "$dir"
done
retry_case claude-once claude fail-once transient-claude.txt
test "$code" -eq 0; check_status done 1
sed -n 2p "$dir/argv" | grep -q -- '-p Continue the task. The previous attempt was interrupted by: API Error: Connection lost mid-response.*--resume 34cb7732-ccc0-4988-a249-147c0ddeb20a'
retry_case always codex fail-always transient-codex.txt
test "$code" -eq 1; check_status failed 2; test "$(wc -l < "$dir/argv")" -eq 3
for a in codex claude; do
  retry_case "real-$a" "$a" fail-always nontransient.txt
  test "$code" -eq 1; check_status failed 0; test "$(wc -l < "$dir/argv")" -eq 1
done
retry_case nosession codex fail-nosession transient-codex.txt
test "$code" -eq 1; check_status failed 0; test "$(wc -l < "$dir/argv")" -eq 1
retry_case off codex fail-always transient-codex.txt RETRY=0
test "$code" -eq 1; check_status failed 0; test "$(wc -l < "$dir/argv")" -eq 1

echo PASS
