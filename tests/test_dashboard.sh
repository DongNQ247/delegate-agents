#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
trap 'echo "FAIL: command failed: $BASH_COMMAND" >&2' ERR

require() {
  if ! "$@"; then
    fail "$*"
  fi
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
export DELEGATE_CODEX_SESSIONS="$tmp/codex-sessions"
mkdir -p "$DELEGATE_CODEX_SESSIONS/2026/11/19"
cat > "$DELEGATE_CODEX_SESSIONS/2026/11/19/rollout-test-thread.jsonl" <<'JSONL'
{"timestamp":"2026-11-19T08:24:41.759Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"resets_at":4102444800},"secondary":{"used_percent":34,"resets_at":4102444800}}}}
JSONL

server_pid=
server_pid2=
cleanup() {
  bash "$root/dashboard.sh" stop "$repo" >/dev/null 2>&1 || true
  bash "$root/dashboard.sh" stop "$repo2" >/dev/null 2>&1 || true
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

(cd "$tmp" && bash "$root/dashboard.sh" start "$repo" >/dev/null) || fail "first dashboard start failed"
require grep -qx '.agents/' "$repo/.git/info/exclude"
server_pid=$(cat "$repo/.agents/server.pid")
port=$(cat "$repo/.agents/server.port")

status=$(curl -sS -o "$tmp/quota-response.json" -w '%{http_code}' "http://localhost:$port/quota.json")
require test "$status" = 200
if ! python3 - "$tmp/quota-response.json" "$repo/.agents/quota.json" "$DELEGATE_QUOTA" <<'PY'
import json, sys
import os
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
assert isinstance(value, dict), value
assert value["codex"]["five_hour"]["used"] == 0.12, value
assert value["codex"]["week"]["used"] == 0.34, value
assert "claude_gpt" in value.get("agy", {}), value
assert os.path.realpath(sys.argv[2]) == os.path.realpath(sys.argv[3])
PY
then
  fail "quota endpoint does not contain expected codex and agy data or symlink target"
fi
require test -L "$repo/.agents/quota.json"
require test -f "$DELEGATE_QUOTA"
refresher_pid_file="$(dirname "$DELEGATE_QUOTA")/refresher.pid"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$refresher_pid_file" ] && break
  sleep 0.2
done
require test -f "$refresher_pid_file"
refresher_pid=$(sed -n '1p' "$refresher_pid_file")
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid"
require kill -0 "$refresher_pid"

(cd "$tmp" && bash "$root/dashboard.sh" start "$repo2" >/dev/null) || fail "second dashboard start failed"
server_pid2=$(cat "$repo2/.agents/server.pid")
require test "$(sed -n '1p' "$refresher_pid_file")" = "$refresher_pid"
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid"
loop_count=$( (pgrep -f -- "$refresher_marker" || true) | wc -l )
require test "$loop_count" -eq 1

kill "$server_pid" 2>/dev/null || fail "could not stop first dashboard server"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  kill -0 "$refresher_pid" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$refresher_pid" 2>/dev/null; then
  fail "refresher did not exit after its bound server died"
fi

# A start against a live repo must replace a refresher whose server binding died.
(cd "$tmp" && bash "$root/dashboard.sh" start "$repo2" >/dev/null) || fail "restart against second dashboard failed"
new_refresher_pid=$(sed -n '1p' "$refresher_pid_file")
require test "$new_refresher_pid" != "$refresher_pid"
require test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid2"
require kill -0 "$new_refresher_pid"

bash "$root/dashboard.sh" stop "$repo" >/dev/null
for _ in 1 2 3 4 5; do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$server_pid" 2>/dev/null; then
  fail "first dashboard server is still running after stop"
fi
require test ! -e "$repo/.agents/server.pid"
require test ! -e "$repo/.agents/server.port"
bash "$root/dashboard.sh" stop "$repo2" >/dev/null
for _ in 1 2 3 4 5; do
  kill -0 "$server_pid2" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$server_pid2" 2>/dev/null; then
  fail "second dashboard server is still running after stop"
fi
require test ! -e "$repo2/.agents/server.pid"
require test ! -e "$repo2/.agents/server.port"
require test ! -e "$refresher_pid_file"
loop_count=$( (pgrep -f -- "$refresher_marker" || true) | wc -l )
require test "$loop_count" -eq 0

echo PASS
