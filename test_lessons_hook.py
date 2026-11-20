"""Self-test for lessons-hook.py: python3 test_lessons_hook.py"""
import json, os, subprocess, sys, tempfile

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lessons-hook.py")

def bash(cmd): return {"type": "tool_use", "name": "Bash", "input": {"command": cmd}}
def edit(path): return {"type": "tool_use", "name": "Edit", "input": {"file_path": path}}
def text(t): return {"type": "text", "text": t}
def result(t): return {"type": "user", "message": {"content": [{"type": "tool_result", "content": t}]}}

def run(entries, extra=None, env=None):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for e in entries:
            line = e if e.get("type") == "user" else {"type": "assistant", "message": {"content": [e]}}
            f.write(json.dumps(line) + "\n")
    payload = {"transcript_path": f.name, **(extra or {})}
    out = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True, text=True,
                         env={**os.environ, **env} if env else None).stdout
    os.unlink(f.name)
    return out

RA = "AGENTS_LOG=/r/.agents/status.jsonl bash ~/.claude/skills/delegate-agents/run-agent.sh codex gpt-6-luna low /r/wt t - \"do X\""
cases = [
    # (name, entries, expect: None | "LESSONS" | "REPORT")
    ("no skill use", [bash("ls"), text("hi")], None),
    ("dispatch alone no longer nags", [bash(RA)], None),
    ("$RA dispatch alone", [bash('bash $RA agy m - /w id - "p" &')], None),
    ("dispatch then edit LESSONS", [bash(RA), edit("/h/LESSONS.md")], None),
    ("dispatch then 'nothing new' text", [bash(RA), text("Nothing new for LESSONS.md.")], None),
    # the three real false alarms:
    ("fixture strings in quotes", [bash("printf 'bash run-agent.sh codex\\ngit merge x\\n' > t.jsonl")], None),
    ("ls output names the script", [bash("ls ~/.claude/skills/delegate-agents"), result("run-agent.sh\nLESSONS.md")], None),
    ("grep for the script", [bash("grep -n run-agent SKILL.md")], None),
    ("merge without skill", [bash("git merge feature")], None),
    ("lessons edited BEFORE merge still nags after", [bash(RA), edit("/h/LESSONS.md"), bash("git merge --no-edit -q t")], "BOTH"),
    ("merge then both handled", [bash(RA), bash("git merge t"), edit("/r/.agents/REPORT.md"), edit("/h/LESSONS.md")], None),
    ("merge --abort ignored", [bash(RA), edit("/h/LESSONS.md"), bash("git merge --abort")], None),
    ("new dispatch after lessons", [bash(RA), edit("/h/LESSONS.md"), bash(RA)], None),
    ("merge after dispatch, nothing handled", [bash(RA), bash("git merge t")], "BOTH"),
    ("merge, lessons handled, report not", [bash(RA), bash("git merge t"), edit("/h/LESSONS.md")], "REPORT"),
]
fails = 0
for name, entries, expect in cases:
    out = run(entries)
    got = None if not out else ("BOTH" if "REPORT.md" in out and "LESSONS.md" in out else "REPORT" if "REPORT.md" in out else "LESSONS")
    ok = got == expect
    fails += not ok
    print(f"{'ok ' if ok else 'FAIL'} {name}: expected {expect}, got {got}")
assert run([bash(RA), bash("git merge t")], {"stop_hook_active": True}) == "", "must not loop"
assert subprocess.run([sys.executable, HOOK], input="garbage", capture_output=True, text=True).returncode == 0
merge = [bash(RA), bash("git merge t")]
assert "/d/LESSONS.md" in run(merge, env={"CLAUDE_PLUGIN_DATA": "/d"}), "LESSONS must follow CLAUDE_PLUGIN_DATA"
assert os.path.join(os.path.dirname(HOOK), "LESSONS.md") in run(merge, env={"CLAUDE_PLUGIN_DATA": ""}), "empty CLAUDE_PLUGIN_DATA = unset"
print("loop guard ok, bad input ok, data path ok")
sys.exit(1 if fails else 0)
