#!/usr/bin/env bash
# Run one worker headless and log start/end to $AGENTS_LOG for dashboard.html.
# usage: AGENTS_LOG=/abs/repo/.agents/status.jsonl bash run-agent.sh <codex|agy|claude> <model> <effort|-> <abs-dir> <id> <parent|-> "<prompt>"
# env: MODE=ro (read-only review), TIMEOUT=600, WAVE=N (parallel wave, shown on the dashboard),
#      RESUME=<earlier id> (continue that worker's session; same agent),
#      RETRY=2 (resumes after a verified transient error; 0 disables), RETRY_WAIT="30 90" (seconds before each retry)
# stop:  AGENTS_LOG=... bash run-agent.sh stop <id>   (cancel a running worker; final status "cancelled")
set -u
safe() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] && [[ $1 != .* ]]; }  # id/parent become file names under .agents
if [ "${1:-}" = stop ]; then
  [ $# -eq 2 ] && safe "$2" || { echo "usage: run-agent.sh stop id" >&2; exit 2; }
  agents=$(dirname "${AGENTS_LOG:?set AGENTS_LOG to the status.jsonl of the workers}")
  pgid=$(cat "$agents/$2.pgid" 2>/dev/null) && [ -n "$pgid" ] || { echo "stop: $2 is not running" >&2; exit 1; }
  : > "$agents/$2.cancelled"  # written before the kill so the worker's run-agent reports cancelled
  kill -TERM -- -"$pgid" 2>/dev/null
  exit 0
fi
[ $# -eq 7 ] || { echo "usage: run-agent.sh agent model effort dir id parent prompt" >&2; exit 2; }
agent=$1 model=$2 effort=$3 dir=$4 id=$5 parent=$6 prompt=$7
[[ "$prompt" =~ [^[:space:]] ]] || { echo "usage: run-agent.sh agent model effort dir id parent prompt" >&2; exit 2; }
safe "$id" && { [ "$parent" = - ] || safe "$parent"; } || { echo "usage: run-agent.sh agent model effort dir id parent prompt (id/parent: [A-Za-z0-9._-], no leading dot)" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
log=${AGENTS_LOG:?set AGENTS_LOG to an absolute path like <repo>/.agents/status.jsonl}
case $log in /*) ;; *) log=$PWD/$log;; esac
agents=$(dirname "$log")
mkdir -p "$agents"; rm -f "$agents/$id.cancelled"  # stale marker from an earlier run of this id
out=$agents/$id.out
mode=${MODE:-rw} t=${TIMEOUT:-600}
sid= resumed=()
if [ -n "${RESUME:-}" ]; then
  safe "$RESUME" && [ -s "$agents/$RESUME.session" ] || { echo "RESUME: no session recorded for '$RESUME'" >&2; exit 2; }
  prev=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    try: e=json.loads(l)
    except ValueError: continue
    if e.get("id")==sys.argv[2] and e.get("status")=="running": print(e.get("agent","")); break' "$log" "$RESUME" 2>/dev/null)
  [ "$prev" = "$agent" ] || { echo "RESUME: '$RESUME' ran agent '${prev:-?}', not '$agent'" >&2; exit 2; }
  sid=$(head -1 "$agents/$RESUME.session") resumed=(resumed_from "$RESUME")
fi

emit() {  # key value ... -> one JSON line (short line + O_APPEND keeps parallel writes intact)
  python3 -c 'import json,sys,time; d=dict(zip(sys.argv[1::2],sys.argv[2::2])); d["ts"]=time.time(); print(json.dumps(d))' "$@" >> "$log"
}

wave=(); [ -n "${WAVE:-}" ] && wave=(wave "$WAVE")
emit id "$id" parent "$parent" agent "$agent" model "$model" effort "$effort" dir "$dir" mode "$mode" status running task "${prompt:0:200}" routed_from "${ROUTED_FROM:-}" route_reason "${ROUTE_REASON:-}" ${wave[@]+"${wave[@]}"} ${resumed[@]+"${resumed[@]}"}
exec </dev/null  # Codex otherwise waits forever on an inherited open stdin ("Reading additional input from stdin")
cd "$dir" || { emit id "$id" status failed code 1 summary "cannot cd to $dir"; exit 1; }

if [ -n "${NORMALIZER:-}" ]; then
  normalizer=("$NORMALIZER")
else
  normalizer=(python3 "$here/stream_normalize.py")
fi

run_cli() {
  # timeout leads its own process group; -k KILLs a CLI ignoring TERM, the kill below reaps grandchildren that outlive it
  { timeout -k 10 "$t" "$@" </dev/null 2>"$agents/$id.err" & echo $! >"$agents/$id.pgid"; wait $!; } | \
    AGENT_PROMPT="$prompt" "${normalizer[@]}" "$agent" "$id" "$agents"
  code=${PIPESTATUS[0]}
  kill -KILL -- -"$(cat "$agents/$id.pgid")" 2>/dev/null; rm -f "$agents/$id.pgid"
}

launch() {
case "$agent" in
  codex)
    sb=workspace-write; [ "$mode" = ro ] && sb=read-only
    if [ -n "$sid" ]; then  # resume takes no -s/-C; we already cd'd to dir
      run_cli codex exec resume "$sid" -m "$model" -c model_reasoning_effort="$effort" -c sandbox_mode="$sb" --json -o "$out" "$prompt"
    else
    run_cli codex exec -s "$sb" -m "$model" -c model_reasoning_effort="$effort" -C "$dir" --json -o "$out" "$prompt"
    fi ;;
  agy)
    eff=(); [ "$effort" != - ] && eff=(--effort "$effort")
    m=(--mode accept-edits); [ "$mode" = ro ] && m=(--sandbox)
    [ -n "$sid" ] && m+=(--conversation "$sid")
    run_cli agy -p "$prompt" --model "$model" "${eff[@]}" "${m[@]}" --dangerously-skip-permissions --output-format stream-json ;;
  claude)
    pm=acceptEdits; [ "$mode" = ro ] && pm=plan
    rs=(); [ -n "$sid" ] && rs=(--resume "$sid")
    run_cli claude -p "$prompt" --model "$model" --effort "$effort" --permission-mode "$pm" \
      --allowedTools "${ALLOWED_TOOLS:-Bash(python3 -m pytest:*)}" --output-format stream-json --verbose ${rs[@]+"${rs[@]}"} ;;
  *) emit id "$id" status failed code 2 summary "unknown agent $agent"; exit 2 ;;
esac
}

transient() {  # print the reason if the last attempt failed with a known transient error; only evidence-backed text
  local p pats=()
  case $agent in
    codex) pats=(
      '"message":"stream disconnected before completion: error sending request'  # seen in a local codex session log, 2026-05 (the ": Incomplete response ... content_filter" variant in the codex binary is not transient)
      '"message":"Selected model is at capacity'  # seen in a local codex session log, 2026-10 (codex_error_info server_overloaded)
    ) ;;
    claude) pats=(
      '"text":"API Error: Connection lost mid-response'  # seen in a local Claude Code transcript, 2026-11 (error server_error)
    ) ;;
    *) return 1 ;;  # agy: no transient failure on record yet -> never retried
  esac
  for p in "${pats[@]}"; do
    { cat "$agents/$id.err"; tail -c +$((raw_off + 1)) "$agents/$id.raw.jsonl"; } 2>/dev/null | grep -qF -- "$p" && { echo "${p#*\":\"}"; return 0; }
  done
  return 1
}

retries=${RETRY:-2} waits=(${RETRY_WAIT:-30 90}) n=0
raw_off=$(stat -c %s "$agents/$id.raw.jsonl" 2>/dev/null || echo 0)
launch
while [ "$code" -ne 0 ] && [ "$code" -ne 124 ] && [ ! -e "$agents/$id.cancelled" ] && [ "$n" -lt "$retries" ] && reason=$(transient); do
  if [ -s "$agents/$id.session" ]; then
    sid=$(head -1 "$agents/$id.session") prompt="Continue the task. The previous attempt was interrupted by: $reason."
  elif grep -qv '"kind": "prompt"' "$agents/$id.events.jsonl" 2>/dev/null; then
    break  # work happened but no session to resume: a fresh start could repeat edits
  fi
  n=$((n + 1))
  emit id "$id" status running retry "$n" reason "$reason"
  sleep "${waits[n - 1]:-${waits[${#waits[@]} - 1]}}"
  raw_off=$(stat -c %s "$agents/$id.raw.jsonl" 2>/dev/null || echo 0)
  launch
done
status=done; [ $code -ne 0 ] && status=failed; [ $code -eq 124 ] && status=timeout
[ -e "$agents/$id.cancelled" ] && [ $code -ne 0 ] && status=cancelled  # a stop after a clean exit keeps done
rm -f "$agents/$id.cancelled"
summary=$(grep -v '^\s*$' "$out" 2>/dev/null | tail -1 | cut -c1-300)
if [ "$code" -ne 0 ] && [ -z "$summary" ]; then summary=$(grep -v '^\s*$' "$agents/$id.err" 2>/dev/null | tail -1 | cut -c1-300); fi
emit id "$id" status "$status" code "$code" summary "$summary"
cat "$out" 2>/dev/null | tail -5
if [ "$code" -ne 0 ]; then tail -5 "$agents/$id.err" 2>/dev/null || true; fi
exit $code
