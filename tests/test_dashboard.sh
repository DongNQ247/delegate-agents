#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
repo="$tmp/repo"
repo2="$tmp/repo2"
mkdir -p "$repo" "$repo2"
git -C "$repo" init -q
git -C "$repo2" init -q

export NO_OPEN=1
export DELEGATE_QUOTA="$tmp/state/quota.json"
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

(cd "$tmp" && bash "$root/dashboard.sh" start "$repo" >/dev/null)
grep -qx '.agents/' "$repo/.git/info/exclude"
server_pid=$(cat "$repo/.agents/server.pid")
port=$(cat "$repo/.agents/server.port")

status=$(curl -sS -o "$tmp/quota-response.json" -w '%{http_code}' "http://localhost:$port/quota.json")
test "$status" = 200
python3 - "$tmp/quota-response.json" "$repo/.agents/quota.json" "$DELEGATE_QUOTA" <<'PY'
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
test -L "$repo/.agents/quota.json"
test -f "$DELEGATE_QUOTA"
refresher_pid_file="$(dirname "$DELEGATE_QUOTA")/refresher.pid"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$refresher_pid_file" ] && break
  sleep 0.2
done
test -f "$refresher_pid_file"
refresher_pid=$(sed -n '1p' "$refresher_pid_file")
test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid"
kill -0 "$refresher_pid"

(cd "$tmp" && bash "$root/dashboard.sh" start "$repo2" >/dev/null)
server_pid2=$(cat "$repo2/.agents/server.pid")
test "$(sed -n '1p' "$refresher_pid_file")" = "$refresher_pid"
test "$(sed -n '2p' "$refresher_pid_file")" = "$server_pid"
test "$(pgrep -f 'agy-refresh' | wc -l)" -eq 1

kill "$server_pid"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  kill -0 "$refresher_pid" 2>/dev/null || break
  sleep 0.2
done
! kill -0 "$refresher_pid" 2>/dev/null

bash "$root/dashboard.sh" stop "$repo" >/dev/null
for _ in 1 2 3 4 5; do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$server_pid" 2>/dev/null
test ! -e "$repo/.agents/server.pid"
test ! -e "$repo/.agents/server.port"
bash "$root/dashboard.sh" stop "$repo2" >/dev/null
for _ in 1 2 3 4 5; do
  kill -0 "$server_pid2" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$server_pid2" 2>/dev/null
test ! -e "$repo2/.agents/server.pid"
test ! -e "$repo2/.agents/server.port"
test ! -e "$refresher_pid_file"
! pgrep -f 'agy-refresh' >/dev/null

echo PASS
