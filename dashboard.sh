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

if [ "$cmd" = stop ]; then
  alive && kill "$(cat "$pidf")" && echo "dashboard stopped" || echo "dashboard not running"
  rm -f "$pidf" "$portf"; exit 0
fi
[ "$cmd" = start ] || { echo "unknown command $cmd" >&2; exit 2; }

mkdir -p "$dir"
cp "$here/dashboard.html" "$dir/dashboard.html"   # always refresh to the skill's latest page
touch "$dir/status.jsonl"
QUOTA_PATH=$(PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}" python3 -c 'import quota; print(quota.QUOTA_PATH)')
case "$QUOTA_PATH" in
  /*) ;;
  *) QUOTA_PATH="$PWD/$QUOTA_PATH" ;;
esac
python3 "$here/quota.py" seed || true
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
  setsid python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" </dev/null >/dev/null 2>&1 &
  echo $! > "$pidf"
  echo "$port" > "$portf"
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$port/dashboard.html" && break; sleep 0.3; done
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
