#!/usr/bin/env bash
# Run one worker headless and log start/end to $AGENTS_LOG for dashboard.html.
# usage: AGENTS_LOG=/abs/repo/.agents/status.jsonl bash run-agent.sh <codex|agy|claude> <model> <effort|-> <abs-dir> <id> <parent|-> "<prompt>"
# env: MODE=ro (read-only review), TIMEOUT=600
set -u
[ $# -eq 7 ] || { echo "usage: run-agent.sh agent model effort dir id parent prompt" >&2; exit 2; }
agent=$1 model=$2 effort=$3 dir=$4 id=$5 parent=$6 prompt=$7
log=${AGENTS_LOG:?set AGENTS_LOG to an absolute path like <repo>/.agents/status.jsonl}
mkdir -p "$(dirname "$log")"
out=$(dirname "$log")/$id.out
mode=${MODE:-rw} t=${TIMEOUT:-600}

emit() {  # key value ... -> one JSON line (short line + O_APPEND keeps parallel writes intact)
  python3 -c 'import json,sys,time; d=dict(zip(sys.argv[1::2],sys.argv[2::2])); d["ts"]=time.time(); print(json.dumps(d))' "$@" >> "$log"
}

emit id "$id" parent "$parent" agent "$agent" model "$model" effort "$effort" dir "$dir" mode "$mode" status running task "${prompt:0:200}"
exec </dev/null  # Codex otherwise waits forever on an inherited open stdin ("Reading additional input from stdin")
cd "$dir" || { emit id "$id" status failed code 1 summary "cannot cd to $dir"; exit 1; }

case "$agent" in
  codex)
    sb=workspace-write; [ "$mode" = ro ] && sb=read-only
    timeout "$t" codex exec -s "$sb" -m "$model" -c model_reasoning_effort="$effort" -C "$dir" -o "$out" "$prompt" >/dev/null 2>&1 ;;
  agy)
    eff=(); [ "$effort" != - ] && eff=(--effort "$effort")
    m=(--mode accept-edits); [ "$mode" = ro ] && m=(--sandbox)
    timeout "$t" agy -p "$prompt" --model "$model" "${eff[@]}" "${m[@]}" --dangerously-skip-permissions > "$out" 2>&1 ;;
  claude)
    pm=acceptEdits; [ "$mode" = ro ] && pm=plan
    timeout "$t" claude -p "$prompt" --model "$model" --effort "$effort" --permission-mode "$pm" \
      --allowedTools "${ALLOWED_TOOLS:-Bash(python3 -m pytest:*)}" > "$out" 2>&1 ;;
  *) emit id "$id" status failed code 2 summary "unknown agent $agent"; exit 2 ;;
esac
code=$?
status=done; [ $code -ne 0 ] && status=failed; [ $code -eq 124 ] && status=timeout
summary=$(grep -v '^\s*$' "$out" 2>/dev/null | tail -1 | cut -c1-300)
emit id "$id" status "$status" code "$code" summary "$summary"
cat "$out" 2>/dev/null | tail -5
exit $code
