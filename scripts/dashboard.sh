#!/usr/bin/env bash
# Start (idempotent) or stop the live agent dashboard for a repo, and open it in the browser.
# usage: bash dashboard.sh start <abs repo>   → prints "AGENTS_LOG=..." and the URL
#        bash dashboard.sh stop  <abs repo>
# env: NO_OPEN=1 to skip opening the browser
set -u
cmd=${1:-}; repo=${2:-}
[ -n "$cmd" ] && [ -d "$repo/.git" -o -f "$repo/.git" ] || { echo "usage: dashboard.sh start|stop <abs git repo>" >&2; exit 2; }
dir="$repo/.agents"; pidf="$dir/server.pid"; portf="$dir/server.port"; here=$(dirname "$(readlink -f "$0")")

alive() { [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; }

quota_path() {
  value=$(PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import quota; print(quota.QUOTA_PATH)')
  case "$value" in
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$PWD" "$value" ;;
  esac
}

write_refresher_state() {
  temporary="$refresher_pidf.tmp.$$"
  printf '%s\n%s\n' "$refresher_pid" "$server_pids" > "$temporary" &&
    mv -f "$temporary" "$refresher_pidf"
}

if [ "$cmd" = stop ]; then
  server_pid=$(cat "$pidf" 2>/dev/null || true)
  quota_path=$(quota_path)
  refresher_pidf="$(dirname "$quota_path")/refresher.pid"
  if [ -n "$server_pid" ] && [ -f "$refresher_pidf" ]; then
    refresher_pid=$(sed -n '1p' "$refresher_pidf")
    bound_server_pids=$(sed -n '2p' "$refresher_pidf")
    remaining_server_pids=()
    for bound_server_pid in $bound_server_pids; do
      if [ "$bound_server_pid" != "$server_pid" ]; then
        remaining_server_pids+=("$bound_server_pid")
      fi
    done
    if [ "${#remaining_server_pids[@]}" -eq 0 ]; then
      kill -- "-$refresher_pid" 2>/dev/null || true
      rm -f "$refresher_pidf"
    else
      server_pids=${remaining_server_pids[*]}
      write_refresher_state
    fi
  fi
  alive && kill "$(cat "$pidf")" && echo "dashboard stopped" || echo "dashboard not running"
  rm -f "$pidf" "$portf"; exit 0
fi
[ "$cmd" = start ] || { echo "unknown command $cmd" >&2; exit 2; }

mkdir -p "$dir"
cp "$here/dashboard.html" "$dir/dashboard.html"   # always refresh to the skill's latest page
touch "$dir/status.jsonl"
QUOTA_PATH=$(quota_path)
mkdir -p "$(dirname "$QUOTA_PATH")"
[ -f "$QUOTA_PATH" ] || printf '{}\n' > "$QUOTA_PATH"
ln -sfn "$QUOTA_PATH" "$dir/quota.json"
excl="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$excl")"; grep -qx '.agents/' "$excl" 2>/dev/null || echo '.agents/' >> "$excl"

if ! alive; then
  port=8765
  # first free port from 8765 (another repo's dashboard may hold one)
  while python3 -c "import socket,sys; s=socket.socket(); sys.exit(s.connect_ex(('127.0.0.1',$port))!=0)"; do port=$((port+1)); done
  # setsid + full redirection: no inherited pipe (callers using `| tail` would hang); $! is the server itself
  setsid python3 "$here/dashboard_server.py" "$port" "$dir" </dev/null >/dev/null 2>&1 &
  echo $! > "$pidf"
  echo "$port" > "$portf"
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$port/dashboard.html" && break; sleep 0.3; done
fi

# Keep one user-scoped refresher serving every live dashboard server.
refresher_pidf="$(dirname "$QUOTA_PATH")/refresher.pid"
server_pid=$(cat "$pidf")
refresher_pid=$(sed -n '1p' "$refresher_pidf" 2>/dev/null || true)
if [ -z "$refresher_pid" ] || ! kill -0 "$refresher_pid" 2>/dev/null; then
  interval=${DELEGATE_AGY_INTERVAL:-300}
  refresher_marker="dashboard-refresher:$(dirname "$QUOTA_PATH")"
  setsid sh -c 'while :; do python3 "$3" refresh-all; sleep "$4"; server_pids=$(sed -n "2p" "$5" 2>/dev/null); alive=0; for pid in $server_pids; do if kill -0 "$pid" 2>/dev/null; then alive=1; fi; done; [ "$alive" -eq 1 ] || exit; done' sh "$refresher_marker" "$server_pid" "$here/quota.py" "$interval" "$refresher_pidf" </dev/null >/dev/null 2>&1 &
  refresher_pid=$!
  server_pids=$server_pid
  write_refresher_state
else
  server_pids=$(sed -n '2p' "$refresher_pidf" 2>/dev/null || true)
  case " $server_pids " in
    *" $server_pid "*) ;;
    *) server_pids="${server_pids:+$server_pids }$server_pid" ;;
  esac
  write_refresher_state
fi
url="http://localhost:$(cat "$portf")/dashboard.html"

if [ -z "${NO_OPEN:-}" ]; then
  if command -v wslview >/dev/null; then wslview "$url"
  elif grep -qi microsoft /proc/version 2>/dev/null && command -v explorer.exe >/dev/null; then explorer.exe "$url"
  elif command -v xdg-open >/dev/null; then xdg-open "$url"
  elif command -v open >/dev/null; then open "$url"
  fi >/dev/null 2>&1 || true   # explorer.exe exits 1 even on success
fi
echo "AGENTS_LOG=$dir/status.jsonl"
echo "dashboard: $url"
