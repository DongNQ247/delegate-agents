#!/usr/bin/env python3
"""Per-user quota snapshots and quota-aware vendor routing."""
import fcntl
import glob
import json
import os
import sys
import tempfile
import time
from datetime import datetime


QUOTA_PATH = os.environ.get(
    "DELEGATE_QUOTA",
    os.path.join(os.path.dirname(__file__), "state", "quota.json"),
)


def load():
    try:
        with open(QUOTA_PATH, encoding="utf-8") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def update(vendor, five_hour, week, updated):
    directory = os.path.dirname(os.path.abspath(QUOTA_PATH))
    os.makedirs(directory, exist_ok=True)
    lock_path = QUOTA_PATH + ".lock"
    with open(lock_path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load()
        if data.get(vendor, {}).get("updated", float("-inf")) > updated:
            return
        data[vendor] = {"five_hour": five_hour, "week": week, "updated": updated}
        fd, temporary = tempfile.mkstemp(dir=directory, suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(data, stream)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, QUOTA_PATH)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def codex_from_rollout(thread_id=None, sessions_dir="~/.codex/sessions"):
    files = glob.glob(os.path.join(os.path.expanduser(sessions_dir), "**", "*.jsonl"), recursive=True)
    if thread_id:
        files = [path for path in files if thread_id in os.path.basename(path)]
    for path in sorted(files, key=os.path.getmtime, reverse=True):
        found = None
        try:
            with open(path, encoding="utf-8") as stream:
                for line in stream:
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    payload = row.get("payload", {})
                    limits = payload.get("rate_limits")
                    if payload.get("type") != "token_count" or not limits:
                        continue
                    stamp = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).timestamp()
                    def window(value):
                        return {"used": value["used_percent"] / 100, "resets_at": value["resets_at"]}
                    found = window(limits["primary"]), window(limits["secondary"]), stamp
        except (OSError, KeyError, TypeError, ValueError):
            continue
        if found:
            return found
    return None


def headroom(entry, now):
    if not entry or now >= entry["five_hour"]["resets_at"]:
        return None
    return 1 - max(entry["five_hour"]["used"], entry.get("week", {}).get("used", 0))


def _near(entry, now):
    return bool(
        entry
        and now < entry["five_hour"]["resets_at"]
        and (entry["five_hour"]["used"] >= .85 or entry.get("week", {}).get("used", 0) >= .90)
    )


def pick(preferred, eligible, now, data=None):
    data = load() if data is None else data
    if not eligible:
        return preferred, "capability"
    if preferred == "-":
        ranked = [(headroom(data.get(vendor), now), -index, vendor)
                  for index, vendor in enumerate(eligible)]
        known = [item for item in ranked if item[0] is not None]
        return (max(known)[2], "quota headroom") if known else (eligible[0], "capability")
    entry = data.get(preferred)
    if preferred not in eligible or not _near(entry, now):
        return preferred, "capability"
    alternatives = []
    for vendor in eligible:
        candidate = data.get(vendor)
        if vendor in (preferred, "agy") or not candidate or _near(candidate, now):
            continue
        amount = headroom(candidate, now)
        if amount is not None:
            alternatives.append((amount, -eligible.index(vendor), vendor))
    if alternatives:
        vendor = max(alternatives)[2]
        if entry["five_hour"]["used"] >= .85:
            detail = f"5h at {entry['five_hour']['used']:.0%} (≥85%)"
        else:
            detail = f"week at {entry['week']['used']:.0%} (≥90%)"
        return vendor, f"switched from {preferred}: {detail}"
    if "agy" in eligible:
        return "agy", f"switched from {preferred}: quota unavailable"
    return preferred, f"warning: {preferred} quota near limit"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "seed":
        result = codex_from_rollout()
        if result:
            update("codex", result[0], result[1], result[2])
        return 0
    if len(argv) >= 3 and argv[0] == "pick":
        vendor, reason = pick(argv[1], argv[2:], time.time())
        print(f"{vendor}\t{reason}")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
