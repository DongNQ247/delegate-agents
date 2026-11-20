#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
trap 'echo "FAIL: command failed: $BASH_COMMAND" >&2' ERR

wait_for() {  # wait_for <seconds> <command...>: poll every 0.2s until it succeeds or the deadline passes
  local end=$((SECONDS + $1)); shift
  until "$@"; do
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 0.2
  done
}

require() {
  if "$@"; then
    return 0
  else
    fail "$*"
  fi
}

is_dead() {
  if kill -0 "$1" 2>/dev/null; then
    return 1
  fi
  return 0
}

different() {
  if [ "$1" = "$2" ]; then
    return 1
  fi
  return 0
}

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
repo="$tmp/repo"
repo2="$tmp/repo2"
mkdir -p "$repo" "$repo2"
git -C "$repo" init -q
git -C "$repo2" init -q

export NO_OPEN=1
export DELEGATE_QUOTA="$tmp/state/quota.json"
refresher_marker="dashboard-refresher:$(dirname "$DELEGATE_QUOTA")"
export DELEGATE_AGY_BIN="$tmp/fake-agy"
export DELEGATE_AGY_INTERVAL=1
cat > "$DELEGATE_AGY_BIN" <<'SH'
#!/usr/bin/env sh
cat "$(dirname "$0")/agy-usage.txt"
SH
chmod +x "$DELEGATE_AGY_BIN"
cp "$root/tests/fixtures/agy-usage.txt" "$tmp/agy-usage.txt"
export DELEGATE_CLAUDE_BIN="$tmp/fake-claude"
cat > "$DELEGATE_CLAUDE_BIN" <<'SH'
#!/usr/bin/env sh
cat "$(dirname "$0")/claude-usage.txt"
SH
chmod +x "$DELEGATE_CLAUDE_BIN"
cp "$root/tests/fixtures/claude-usage.txt" "$tmp/claude-usage.txt"
export DELEGATE_CODEX_SESSIONS="$tmp/codex-sessions"
mkdir -p "$DELEGATE_CODEX_SESSIONS/2026/11/19"
cp "$root/tests/fixtures/codex-rollout-sample.jsonl" "$DELEGATE_CODEX_SESSIONS/2026/11/19/rollout-x.jsonl"

server_pid=
server_pid2=
crash_server_pid=
cleanup() {
  bash "$root/scripts/dashboard.sh" stop "$repo" >/dev/null 2>&1 || true
  bash "$root/scripts/dashboard.sh" stop "$repo2" >/dev/null 2>&1 || true
  if [ -n "$server_pid" ]; then
    for _ in 1 2 3 4 5; do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      kill "$server_pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

(cd "$tmp" && bash "$root/scripts/dashboard.sh" start "$repo" >/dev/null) || fail "first dashboard start failed"
require grep -qx '.agents/' "$repo/.git/info/exclude"
server_pid=$(cat "$repo/.agents/server.pid")
port=$(cat "$repo/.agents/server.port")

status=$(curl -sS -o "$tmp/quota-response.json" -w '%{http_code}' "http://localhost:$port/quota.json")
require test "$status" = 200
python3 - "$repo/.agents/quota.json" "$DELEGATE_QUOTA" <<'PY' || fail "quota symlink target is incorrect"
import json, sys
import os
assert os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2])
PY
require test -L "$repo/.agents/quota.json"
require test -f "$DELEGATE_QUOTA"
refresher_pid_file="$(dirname "$DELEGATE_QUOTA")/refresher.pid"
require wait_for 15 test -f "$refresher_pid_file"
refresher_pid=$(sed -n '1p' "$refresher_pid_file")
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid"
require kill -0 "$refresher_pid"

# The first refresher pass supplies all three vendors shortly after startup.
all_vendors_refreshed() {
  curl -fsS "http://localhost:$port/quota.json" -o "$tmp/quota-response.json" || return 1
  python3 - "$tmp/quota-response.json" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
    assert "claude" in value
    assert "codex" in value
    assert "agy" in value
except (AssertionError, OSError, ValueError):
    sys.exit(1)
PY
}
require wait_for 15 all_vendors_refreshed
first_updated=$(python3 - "$tmp/quota-response.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["agy"]["claude_gpt"]["updated"])
PY
)
python3 - "$tmp/quota-response.json" <<'PY' || fail "all vendor data did not appear in the dashboard quota endpoint shortly after start"
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert "claude" in value, value
assert "codex" in value, value
assert value["claude"]["five_hour"]["used"] == 0.18, value
assert value["claude"]["week"]["used"] == 0.40, value
assert value["codex"]["five_hour"]["used"] == 0.02, value
assert value["codex"]["week"]["used"] == 0.01, value
assert "claude_gpt" in value.get("agy", {}), value
PY

# Only the files dashboard.html fetches are served, and only to a localhost Host header.
http_code() {  # http_code <path> [curl args...]
  local path=$1; shift
  curl -s -o /dev/null -w '%{http_code}' --path-as-is "$@" "http://127.0.0.1:$port/$path"
}
printf '{"id":"a1"}\n' > "$repo/.agents/a1.events.jsonl"
mkdir -p "$repo/.agents/research"
for f in a1.raw.jsonl a1.err a1.out a1.session research/x.md; do echo secret > "$repo/.agents/$f"; done
for path in dashboard.html "status.jsonl?t=1" quota.json a1.events.jsonl; do
  require test "$(http_code "$path")" = 200
done
require test "$(http_code dashboard.html -H 'Host: localhost')" = 200
for path in a1.raw.jsonl a1.err a1.out a1.session research/x.md ../repo/.agents/status.jsonl "%2e%2e/x" .events.jsonl "" research/; do
  code=$(http_code "$path")
  case "$code" in 403|404) ;; *) fail "/$path returned $code" ;; esac
done
require test "$(http_code dashboard.html -H 'Host: evil.example')" = 403
require test "$(http_code dashboard.html -H "Host: evil.example:$port")" = 403

(cd "$tmp" && bash "$root/scripts/dashboard.sh" start "$repo2" >/dev/null) || fail "second dashboard start failed"
server_pid2=$(cat "$repo2/.agents/server.pid")
require test "$(sed -n '1p' "$refresher_pid_file")" = "$refresher_pid"
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid $server_pid2"
loop_count=$( (pgrep -f -- "$refresher_marker" || true) | wc -l )
require test "$loop_count" -eq 1

bash "$root/scripts/dashboard.sh" stop "$repo" >/dev/null
for _ in 1 2 3 4 5; do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$server_pid" 2>/dev/null; then
  fail "first dashboard server is still running after stop"
fi
if [ -e "$repo/.agents/server.pid" ] || [ -e "$repo/.agents/server.port" ]; then
  fail "first dashboard state files remain after stop"
fi
require test "$(sed -n '1p' "$refresher_pid_file")" = "$refresher_pid"
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid2"
require kill -0 "$refresher_pid"
quota_updated_changed() {
  current_updated=$(python3 - "$DELEGATE_QUOTA" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8"))["agy"]["claude_gpt"]["updated"])
except (OSError, KeyError, ValueError):
    print("")
PY
  )
  [ -n "$current_updated" ] && different "$current_updated" "$first_updated"
}
require wait_for 15 quota_updated_changed

bash "$root/scripts/dashboard.sh" stop "$repo2" >/dev/null
for _ in 1 2 3 4 5; do
  kill -0 "$server_pid2" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$server_pid2" 2>/dev/null; then
  fail "second dashboard server is still running after stop"
fi
if [ -e "$repo2/.agents/server.pid" ] || [ -e "$repo2/.agents/server.port" ]; then
  fail "second dashboard state files remain after stop"
fi
if [ -e "$refresher_pid_file" ]; then
  fail "refresher state file remains after final stop"
fi
loop_count=$( (pgrep -f -- "$refresher_marker" || true) | wc -l )
require test "$loop_count" -eq 0

# Directly killing all served servers still lets the loop exit on its own.
(cd "$tmp" && bash "$root/scripts/dashboard.sh" start "$repo" >/dev/null) || fail "crash-case dashboard start failed"
crash_server_pid=$(cat "$repo/.agents/server.pid")
crash_refresher_pid=$(sed -n '1p' "$refresher_pid_file")
(cd "$tmp" && bash "$root/scripts/dashboard.sh" start "$repo2" >/dev/null) || fail "second crash-case dashboard start failed"
crash_server_pid2=$(cat "$repo2/.agents/server.pid")
require test "$(sed -n '2p' "$refresher_pid_file")" = "$crash_server_pid $crash_server_pid2"
kill "$crash_server_pid" "$crash_server_pid2" 2>/dev/null || fail "could not kill crash-case dashboard servers"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if is_dead "$crash_refresher_pid"; then break; fi
  sleep 0.2
done
if kill -0 "$crash_refresher_pid" 2>/dev/null; then
  fail "refresher did not exit after all served servers died"
fi
# Starting a live server replaces the stale refresher state after a crash.
(cd "$tmp" && bash "$root/scripts/dashboard.sh" start "$repo2" >/dev/null) || fail "restart after crash failed"
server_pid2=$(cat "$repo2/.agents/server.pid")
new_refresher_pid=$(sed -n '1p' "$refresher_pid_file")
require different "$new_refresher_pid" "$crash_refresher_pid"
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid2"
bash "$root/scripts/dashboard.sh" stop "$repo2" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if is_dead "$new_refresher_pid"; then break; fi
  sleep 0.2
done
if kill -0 "$new_refresher_pid" 2>/dev/null; then
  fail "final crash-recovery refresher is still running after stop"
fi
if [ -e "$refresher_pid_file" ]; then
  fail "crash-recovery refresher state file remains after final stop"
fi

echo PASS
