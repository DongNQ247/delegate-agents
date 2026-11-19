import importlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
NOW = 1_795_000_000.0


def fixture_rows(agent):
    with (FIXTURES / f"{agent}.jsonl").open(encoding="utf-8") as stream:
        return [json.loads(line) for line in stream]


def normalize_rows(agent, rows):
    import stream_normalize

    events = []
    final_text = None
    hints = []
    for row in rows:
        new_events, text, hint = stream_normalize.normalize(agent, row, NOW)
        events.extend(new_events)
        if text is not None:
            final_text = text
        if hint is not None:
            hints.append(hint)
    return events, final_text, hints


def test_claude_fixture_normalizes_tools_final_text_and_quota():
    events, final_text, hints = normalize_rows("claude", fixture_rows("claude"))

    assert any(event["kind"] == "tool" and ("Read" in event["text"] or "Bash" in event["text"])
               for event in events)
    assert final_text
    assert len(hints) == 1
    assert hints[0]["vendor"] == "claude"
    assert hints[0]["five_hour"]["used"] == 0.3
    assert hints[0]["week"]["used"] == 0.28


def test_codex_fixture_normalizes_command_message_end_and_thread():
    events, _, hints = normalize_rows("codex", fixture_rows("codex"))

    assert any(event["kind"] == "command" and "pytest" in event["text"] for event in events)
    assert any(event["kind"] == "message" for event in events)
    assert any(event["kind"] == "end" for event in events)
    assert {hint["codex_thread"] for hint in hints if "codex_thread" in hint} == {
        "01a1f2e8-3f38-7870-859a-846c5929cfb3"
    }


def test_agy_fixture_normalizes_tools_and_final_text():
    events, final_text, _ = normalize_rows("agy", fixture_rows("agy"))

    assert sum(event["kind"] == "tool" for event in events) >= 2
    assert final_text.startswith("All 92 tests passed")


def test_agent_message_text_is_truncated_to_2000_characters():
    import stream_normalize

    events, _, _ = stream_normalize.normalize(
        "codex",
        {"type": "item.completed", "item": {"type": "agent_message", "text": "x" * 10_000}},
        NOW,
    )

    message = next(event for event in events if event["kind"] == "message")
    assert len(message["text"]) <= 2_000


def test_main_skips_non_json_lines_and_preserves_prompt_and_raw_input(tmp_path):
    fixture = (FIXTURES / "codex.jsonl").read_text(encoding="utf-8")
    input_text = "warning: banner\n" + fixture
    env = os.environ.copy()
    env["AGENT_PROMPT"] = "hi"
    result = subprocess.run(
        [sys.executable, str(ROOT / "stream_normalize.py"), "codex", "agent-1", str(tmp_path)],
        input=input_text,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode == 0
    events = [json.loads(line) for line in (tmp_path / "agent-1.events.jsonl").read_text().splitlines()]
    raw_lines = (tmp_path / "agent-1.raw.jsonl").read_text().splitlines()
    assert events[0]["kind"] == "prompt"
    assert events[0]["text"] == "hi"
    assert len(raw_lines) == len(input_text.splitlines())


def test_main_drains_stdin_after_a_line_error(tmp_path, monkeypatch):
    import stream_normalize

    consumed = io.StringIO("{}\n" * 5_000)
    calls = 0

    def normalize_with_error(agent, obj, now):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise RuntimeError("bad event")
        return [], None, None

    monkeypatch.setattr(stream_normalize, "normalize", normalize_with_error)
    monkeypatch.setattr(sys, "stdin", consumed)
    stream_normalize.main(["claude", "agent-2", str(tmp_path)])

    assert consumed.read() == ""
    assert calls == 5_000


def test_main_writes_agy_final_text_to_out(tmp_path):
    fixture = (FIXTURES / "agy.jsonl").read_text(encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(ROOT / "stream_normalize.py"), "agy", "agent-3", str(tmp_path)],
        input=fixture,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0
    assert (tmp_path / "agent-3.out").read_text(encoding="utf-8") == (
        "All 92 tests passed successfully after reading "
        "[calc.py](file:///home/user/project/demo/calc.py) and "
        "[stats.py](file:///home/user/project/demo/stats.py).\n"
    )


def test_main_updates_claude_quota(tmp_path, monkeypatch):
    quota_path = tmp_path / "quota.json"
    monkeypatch.setenv("DELEGATE_QUOTA", str(quota_path))
    import quota

    importlib.reload(quota)
    fixture = (FIXTURES / "claude.jsonl").read_text(encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(ROOT / "stream_normalize.py"), "claude", "agent-4", str(tmp_path)],
        input=fixture,
        text=True,
        capture_output=True,
        check=False,
        env={**os.environ, "DELEGATE_QUOTA": str(quota_path)},
    )

    assert result.returncode == 0
    assert quota.load()["claude"]["five_hour"]["used"] == 0.3
