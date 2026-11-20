#!/usr/bin/env python3
"""Normalize agent CLI streams into dashboard events and quota snapshots."""
import json
import os
import sys
import time

import quota


TEXT_LIMIT = 2_000
DETAIL_LIMIT = 8_000
SESSION_KEYS = {"codex": "thread_id", "claude": "session_id", "agy": "conversation_id"}


def _short(value, limit=TEXT_LIMIT):
    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return text[:limit]


def _event(kind, now, text="", detail=None):
    event = {"ts": now, "kind": kind, "text": _short(text)}
    if detail is not None:
        event["detail"] = _short(detail, DETAIL_LIMIT)
    return event


def _claude(obj, now):
    events = []
    final_text = None
    hint = None
    kind = obj.get("type")
    if kind == "assistant":
        message = obj.get("message", {})
        for block in message.get("content", []):
            if block.get("type") == "tool_use":
                name = block.get("name", "tool")
                value = block.get("input", {})
                short_input = _short(value, 1_000)
                events.append(_event("tool", now, f"{name}: {short_input}", value))
            elif block.get("type") == "text":
                events.append(_event("message", now, block.get("text", "")))
    elif kind == "user":
        message = obj.get("message", {})
        for block in message.get("content", []):
            if block.get("type") == "tool_result":
                content = block.get("content", "")
                events.append(_event("tool_result", now, content, content))
    elif kind == "result":
        final_text = obj.get("result")
        events.append(_event("end", now, "end"))
    elif kind == "rate_limit_event":
        windows = obj.get("rate_limit_info", {}).get("unifiedWindows", {})
        five_hour = windows.get("five_hour")
        seven_day = windows.get("seven_day")
        if five_hour is not None and seven_day is not None:
            hint = {
                "vendor": "claude",
                "five_hour": {"used": five_hour["utilization"], "resets_at": five_hour["resetsAt"]},
                "week": {"used": seven_day["utilization"], "resets_at": seven_day["resetsAt"]},
                "updated": now,
            }
    return events, final_text, hint


def _codex(obj, now):
    events = []
    final_text = None
    hint = None
    kind = obj.get("type")
    if kind == "thread.started":
        thread_id = obj.get("thread_id")
        if thread_id:
            hint = {"codex_thread": thread_id}
    elif kind in ("item.started", "item.completed"):
        item = obj.get("item", {})
        item_type = item.get("type")
        if kind == "item.started" and item_type == "command_execution":
            events.append(_event("command", now, item.get("command", "")))
        elif kind == "item.completed":
            if item_type == "command_execution":
                events.append(_event(
                    "command_done", now, f"exit {item.get('exit_code')}", item.get("aggregated_output", "")
                ))
            elif item_type == "agent_message":
                events.append(_event("message", now, item.get("text", "")))
            elif item_type == "file_change":
                changes = item.get("changes", item)
                events.append(_event("edit", now, _short(changes), changes))
    elif kind == "turn.completed":
        events.append(_event("end", now, "end"))
    return events, final_text, hint


def _agy(obj, now):
    events = []
    final_text = None
    hint = None
    kind = obj.get("event")
    if kind == "step_update":
        step = obj.get("step_update", {})
        step_type = step.get("step_type")
        state = step.get("state")
        if step_type == "tool" and state in ("ACTIVE", "DONE"):
            info = step.get("tool_info", {})
            name = step.get("tool_name", "tool")
            if state == "ACTIVE":
                events.append(_event("tool", now, f"{name}: {_short(info, 1_000)}", info))
            else:
                result = info.get("output", "") if isinstance(info, dict) else ""
                events.append(_event("tool_result", now, result, result))
    elif kind == "result":
        result = obj.get("result", {})
        final_text = result.get("response")
        events.append(_event("end", now, "end"))
    return events, final_text, hint


def normalize(agent: str, obj: dict, now: float) -> tuple[list[dict], str | None, dict | None]:
    """Return normalized events, optional final text, and optional quota hint."""
    if not isinstance(obj, dict):
        return [], None, None
    if agent == "claude":
        return _claude(obj, now)
    if agent == "codex":
        return _codex(obj, now)
    if agent == "agy":
        return _agy(obj, now)
    return [], None, None


def _write_event(stream, event):
    stream.write(json.dumps(event, ensure_ascii=False) + "\n")
    stream.flush()


def _write_codex_quota(thread_id):
    sessions_dir = os.environ.get("DELEGATE_CODEX_SESSIONS", "~/.codex/sessions")
    snapshot = quota.codex_from_rollout(thread_id, sessions_dir=sessions_dir)
    if snapshot:
        quota.update("codex", snapshot[0], snapshot[1], snapshot[2])


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 3:
        return 2
    agent, agent_id, agents_dir = argv
    raw_path = os.path.join(agents_dir, f"{agent_id}.raw.jsonl")
    events_path = os.path.join(agents_dir, f"{agent_id}.events.jsonl")
    out_path = os.path.join(agents_dir, f"{agent_id}.out")
    thread_id = None
    agy_responses = {}
    last_codex_poll = time.monotonic()
    final_text = None
    session_id = None
    try:
        os.makedirs(agents_dir, exist_ok=True)
    except Exception:
        try:
            for _ in sys.stdin:
                pass
        except Exception:
            pass
        return 0
    try:
        with open(raw_path, "a", encoding="utf-8") as raw, open(events_path, "a", encoding="utf-8") as events:
            prompt = os.environ.get("AGENT_PROMPT")
            if prompt is not None:
                _write_event(events, _event("prompt", time.time(), prompt))
            while True:
                try:
                    line = sys.stdin.readline()
                except Exception:
                    break
                if line == "":
                    break
                try:
                    raw.write(line)
                    raw.flush()
                    try:
                        obj = json.loads(line)
                    except (ValueError, TypeError):
                        continue
                    sid = obj.get(SESSION_KEYS.get(agent)) if isinstance(obj, dict) else None
                    if isinstance(sid, str) and sid and sid != session_id:
                        session_id = sid  # keep the latest: a resume may report a new id
                        with open(os.path.join(agents_dir, f"{agent_id}.session"), "w", encoding="utf-8") as f:
                            f.write(sid + "\n")
                    now = time.time()
                    new_events, text, hint = normalize(agent, obj, now)
                    if agent == "agy" and obj.get("event") == "step_update":
                        step = obj.get("step_update", {})
                        if step.get("step_type") == "agent_response":
                            step_index = step.get("step_index")
                            if step.get("state") == "ACTIVE":
                                agy_responses[step_index] = agy_responses.get(step_index, "") + (
                                    step.get("text_delta") or ""
                                )
                            elif step.get("state") == "DONE":
                                response = agy_responses.pop(step_index, "")
                                if not response.strip():
                                    response = step.get("text") or step.get("text_delta") or ""
                                if response.strip():
                                    new_events.append(_event("message", now, response))
                    for event in new_events:
                        _write_event(events, event)
                    if text is not None:
                        final_text = text
                    if hint and hint.get("vendor"):
                        quota.update(hint["vendor"], hint["five_hour"], hint["week"], hint["updated"])
                    if hint and hint.get("codex_thread"):
                        thread_id = hint["codex_thread"]
                    if agent == "codex" and thread_id and time.monotonic() - last_codex_poll >= 5:
                        _write_codex_quota(thread_id)
                        last_codex_poll = time.monotonic()
                except Exception as error:
                    try:
                        _write_event(events, _event("error", time.time(), str(error)))
                    except Exception:
                        pass
            if agent == "codex" and thread_id:
                try:
                    _write_codex_quota(thread_id)
                except Exception as error:
                    try:
                        _write_event(events, _event("error", time.time(), str(error)))
                    except Exception:
                        pass
    except Exception:
        # The stream is observational; a file or setup error must not stop its producer.
        try:
            for _ in sys.stdin:
                pass
        except Exception:
            pass
    if agent in ("claude", "agy") and final_text is not None:
        try:
            with open(out_path, "w", encoding="utf-8") as output:
                output.write(final_text)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
