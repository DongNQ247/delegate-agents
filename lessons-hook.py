#!/usr/bin/env python3
"""Stop hook for delegate-agents. Reads only Claude's own tool calls and text in the transcript.
- A Bash call that runs run-agent.sh after LESSONS.md was last handled  -> ask to update LESSONS.md
- A Bash `git merge` (in a session that used run-agent.sh) after REPORT.md was last handled
                                                                         -> ask to update .agents/REPORT.md
"Handled" = Write/Edit of the file, a Bash command touching it, or assistant text naming it
(the one-line "nothing new for X" answer)."""
import json, os, re, sys

LESSONS = os.path.expanduser("~/.claude/skills/delegate-agents/LESSONS.md")
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")  # drop quoted text: fixtures, prompts, echo strings
DISPATCH = re.compile(r"\bbash\s+(?:\S*run-agent\.sh|\$\{?RA\}?)\s+(?:codex|agy|claude)\b")
MERGE = re.compile(r"\bgit\s+(?:-C\s+\S+\s+)?merge\b(?!\s+--abort)")

def events(path):
    """Yield (kind, payload) in transcript order from assistant messages only."""
    with open(path, encoding="utf-8", errors="ignore") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "assistant":
                continue
            content = (e.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if b.get("type") == "text":
                    yield "text", b.get("text", "")
                elif b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    if b.get("name") == "Bash":
                        yield "bash", inp.get("command", "")
                    elif b.get("name") in ("Write", "Edit"):
                        yield "file", inp.get("file_path", "")

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return  # never break Stop on bad input
    if data.get("stop_hook_active"):
        return  # already continuing because of this hook: no loop
    path = data.get("transcript_path") or ""
    if not os.path.isfile(path):
        return
    last = {"dispatch": -1, "merge": -1, "LESSONS.md": -1, "REPORT.md": -1}
    for i, (kind, val) in enumerate(events(path)):
        if kind == "bash":
            code = QUOTED.sub("", val)
            if DISPATCH.search(code):
                last["dispatch"] = i
            if MERGE.search(code):
                last["merge"] = i
        for name in ("LESSONS.md", "REPORT.md"):
            if name in val:  # file edit, bash touching it, or text naming it
                last[name] = i
    todo = []
    if last["dispatch"] > last["LESSONS.md"]:
        todo.append(f"append verified lessons to {LESSONS} (promote repeated ones into SKILL.md)")
    if last["dispatch"] >= 0 and last["merge"] > last["REPORT.md"]:
        todo.append("add an entry per merged task to <repo>/.agents/REPORT.md "
                    "(date · task · commit · who per role · tests · review findings · open items); "
                    "promote project rules to AGENTS.md")
    if todo:
        print(json.dumps({
            "decision": "block",
            "reason": "delegate-agents bookkeeping before stopping: " + "; ".join(todo)
                      + ". If there is nothing new, say so in one line naming the file.",
        }))

if __name__ == "__main__":
    main()
