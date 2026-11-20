#!/usr/bin/env bash
# Run one worker headless and log start/end to $AGENTS_LOG for dashboard.html.
# usage: AGENTS_LOG=/abs/repo/.agents/status.jsonl bash run-agent.sh <codex|agy|claude> <model> <effort|-> <abs-dir> <id> <parent|-> "<prompt>"
# env: MODE=ro (read-only review), TIMEOUT=600, WAVE=N (parallel wave, shown on the dashboard)
set -u
[ $# -eq 7 ] || { echo "usage: run-agent.sh agent model effort dir id parent prompt" >&2; exit 2; }
agent=$1 model=$2 effort=$3 dir=$4 id=$5 parent=$6 prompt=$7
[[ "$prompt" =~ [^[:space:]] ]] || { echo "usage: run-agent.sh agent model effort dir id parent prompt" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
log=${AGENTS_LOG:?set AGENTS_LOG to an absolute path like <repo>/.agents/status.jsonl}
case $log in /*) ;; *) log=$PWD/$log;; esac
agents=$(dirname "$log")
mkdir -p "$agents"
out=$agents/$id.out
mode=${MODE:-rw} t=${TIMEOUT:-600}

emit() {  # key value ... -> one JSON line (short line + O_APPEND keeps parallel writes intact)
  python3 -c 'import json,sys,time; d=dict(zip(sys.argv[1::2],sys.argv[2::2])); d["ts"]=time.time(); print(json.dumps(d))' "$@" >> "$log"
}

wave=(); [ -n "${WAVE:-}" ] && wave=(wave "$WAVE")
emit id "$id" parent "$parent" agent "$agent" model "$model" effort "$effort" dir "$dir" mode "$mode" status running task "${prompt:0:200}" routed_from "${ROUTED_FROM:-}" route_reason "${ROUTE_REASON:-}" ${wave[@]+"${wave[@]}"}
exec </dev/null  # Codex otherwise waits forever on an inherited open stdin ("Reading additional input from stdin")
cd "$dir" || { emit id "$id" status failed code 1 summary "cannot cd to $dir"; exit 1; }

if [ -n "${NORMALIZER:-}" ]; then
  normalizer=("$NORMALIZER")
else
  normalizer=(python3 "$here/stream_normalize.py")
fi

run_cli() {
  timeout "$t" "$@" </dev/null 2>"$agents/$id.err" | \
    AGENT_PROMPT="$prompt" "${normalizer[@]}" "$agent" "$id" "$agents"
  code=${PIPESTATUS[0]}
}

case "$agent" in
  codex)
    sb=workspace-write; [ "$mode" = ro ] && sb=read-only
    run_cli codex exec -s "$sb" -m "$model" -c model_reasoning_effort="$effort" -C "$dir" --json -o "$out" "$prompt" ;;
  agy)
    eff=(); [ "$effort" != - ] && eff=(--effort "$effort")
    m=(--mode accept-edits); [ "$mode" = ro ] && m=(--sandbox)
    run_cli agy -p "$prompt" --model "$model" "${eff[@]}" "${m[@]}" --dangerously-skip-permissions --output-format stream-json ;;
  claude)
    pm=acceptEdits; [ "$mode" = ro ] && pm=plan
    run_cli claude -p "$prompt" --model "$model" --effort "$effort" --permission-mode "$pm" \
      --allowedTools "${ALLOWED_TOOLS:-Bash(python3 -m pytest:*)}" --output-format stream-json --verbose ;;
  *) emit id "$id" status failed code 2 summary "unknown agent $agent"; exit 2 ;;
esac
status=done; [ $code -ne 0 ] && status=failed; [ $code -eq 124 ] && status=timeout
summary=$(grep -v '^\s*$' "$out" 2>/dev/null | tail -1 | cut -c1-300)
if [ "$code" -ne 0 ] && [ -z "$summary" ]; then summary=$(grep -v '^\s*$' "$agents/$id.err" 2>/dev/null | tail -1 | cut -c1-300); fi
emit id "$id" status "$status" code "$code" summary "$summary"
cat "$out" 2>/dev/null | tail -5
if [ "$code" -ne 0 ]; then tail -5 "$agents/$id.err" 2>/dev/null || true; fi
exit $code
