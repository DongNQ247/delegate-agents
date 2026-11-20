import pytest
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import waves as W  # noqa: E402

PLANS = os.path.join(ROOT, "docs", "superpowers", "plans")  # local-only (git-ignored); tests needing it skip elsewhere


def run(text, cap=5):
    tasks = W.parse_plan(text)
    es = W.edges(tasks)
    return tasks, es, W.waves(tasks, es, cap)


def task(n, files="- Modify: `f%d.py`", interfaces=""):
    body = "**Files:**\n" + (files % n if "%d" in files else files) + "\n" if files else ""
    if interfaces:
        body += "\n**Interfaces:**\n" + interfaces + "\n"
    return "### Task %d: t%d\n\n%s\n- [ ] **Step 1:** do\n\n" % (n, n, body)


def test_independent():
    assert run(task(1) + task(2))[2] == [[1, 2]]


def test_consumes_task_mention():
    _, es, ws = run(task(1) + task(2, interfaces="- Consumes: `foo` (Task 1)"))
    assert ws == [[1], [2]]
    assert "Task 1" in es[0]["reason"]


def test_transitive_file_conflict():
    f = "- Modify: `a.py`"
    assert run(task(1, f) + task(2, f) + task(3, f))[2] == [[1], [2], [3]]


def test_cap_split_keeps_order():
    assert run("".join(task(i) for i in range(1, 7)))[2] == [[1, 2, 3, 4, 5], [6]]


def test_no_files_block():
    tasks, es, ws = run(task(1) + task(2, files=""))
    assert not tasks[1]["files_known"]
    assert es == [{"from": 1, "to": 2, "reason": "no Files block"}]
    assert ws == [[1], [2]]


def test_readonly_fixture_no_conflict():
    f = "- Modify: `f%d.py`\n- Fixtures (exist): `f.txt`"
    tasks, _, ws = run(task(1, f) + task(2, f))
    assert ws == [[1, 2]]
    assert tasks[0]["readonly"] == {"f.txt"}


def test_brace_glob_conflict():
    _, _, ws = run(task(1, "- Test: `tests/{a,b}.py`") + task(2, "- Modify: `./tests/b.py:10-20`"))
    assert ws == [[1], [2]]


def test_inline_files_line():
    text = "### Task 1: x\n\n**Files:** modify `x.py` and `y.py`.\n\n- [ ] go\n"
    assert W.parse_plan(text)[0]["files"] == {"x.py", "y.py"}


def test_module_prefixed_identifier():
    t1 = task(1, interfaces="- Produces:\n  - `update(vendor: str) -> None`")
    t2 = task(2, interfaces="- Consumes: `quota.update`")
    _, es, ws = run(t1 + t2)
    assert ws == [[1], [2]]
    assert "update" in es[0]["reason"]


def read(name):
    path = os.path.join(PLANS, name)
    if not os.path.exists(path):
        pytest.skip("local plan docs not present")
    with open(path) as f:
        return f.read()


def test_real_plans_parse():
    for name in ("2026-11-19-dashboard-v2.md", "2026-11-19-refresh-all-vendors.md",
                 "2026-11-19-dashboard-live-quota.md"):
        assert W.parse_plan(read(name))
    tasks = W.parse_plan(read("2026-11-19-refresh-all-vendors.md"))
    assert [t["files_known"] for t in tasks] == [True, True]
    assert tasks[0]["files"] == {"quota.py", "tests/test_quota.py"}


def test_dashboard_v2_waves():
    # By hand:
    # T1 files quota.py, tests/test_quota.py (fixtures read-only); no Consumes -> wave 1.
    # T2 files dashboard.sh, tests/test_dashboard.sh; Consumes says "(Task 1)" -> wave 2.
    # T3 files dashboard.html, tests/test_dashboard_js.js (Reference ignored); Consumes
    #    `quota.json`/`status.jsonl` match no earlier Produces or file -> wave 1.
    # T4 files SKILL.md; no Interfaces -> wave 1.
    _, es, ws = run(read("2026-11-19-dashboard-v2.md"))
    assert ws == [[1, 3, 4], [2]]
    assert [(e["from"], e["to"]) for e in es] == [(1, 2)]


def cli(*args):
    return subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "waves.py"), *args],
                          capture_output=True, text=True)


def synthetic_plan(tmp_path):
    p = tmp_path / "plan.md"
    p.write_text(task(1) + task(2, interfaces="- Consumes: `x` (Task 1)") + task(3))
    return str(p)


def test_cli_json(tmp_path):
    r = cli(synthetic_plan(tmp_path), "--json")
    assert r.returncode == 0
    assert json.loads(r.stdout)["waves"] == [[1, 3], [2]]


def test_cli_markdown_and_no_tasks(tmp_path):
    r = cli(synthetic_plan(tmp_path))
    assert r.returncode == 0 and "| Wave | Tasks | Waits for |" in r.stdout
    p = tmp_path / "empty.md"
    p.write_text("# nothing\n")
    assert cli(str(p)).returncode != 0


def test_inline_files_existing_named_file_kept():
    # "exist" inside a path or a non-fixture sentence must not hide a written file
    text = "### Task 1: x\n\n**Files:** modify `existing_helper.py`. Extend the existing parser in `p.py`.\n\n- [ ] go\n"
    assert W.parse_plan(text)[0]["files"] == {"existing_helper.py", "p.py"}


def test_inline_files_fixture_sentence_dropped():
    text = "### Task 1: x\n\n**Files:** modify `q.py`. The fixtures exist: `f.txt`.\n\n- [ ] go\n"
    assert W.parse_plan(text)[0]["files"] == {"q.py"}


def test_consumes_everything_above():
    t3 = task(3, "- Modify: `c.py`", interfaces="- Consumes: everything above.")
    _, es, ws = run(task(1, "- Modify: `a.py`") + task(2, "- Modify: `b.py`") + t3)
    assert ws == [[1, 2], [3]]
    assert {(e["from"], e["to"]) for e in es} == {(1, 3), (2, 3)}
