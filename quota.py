#!/usr/bin/env python3
"""Per-user quota snapshots and quota-aware vendor routing."""
import fcntl
import glob
import json
import os
import re
import subprocess
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


def _write_locked(change):
    directory = os.path.dirname(os.path.abspath(QUOTA_PATH))
    os.makedirs(directory, exist_ok=True)
    with open(QUOTA_PATH + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load()
        changed = change(data)
        if not changed:
            return False
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
        return True


def update_agy(pools, updated):
    def merge(data):
        agy = data.setdefault("agy", {})
        changed = False
        for pool, windows in pools.items():
            existing = agy.get(pool, {})
            if existing.get("updated", float("-inf")) > updated:
                continue
            if not existing and "five_hour" not in windows:
                continue
            merged = dict(existing)
            merged.update({key: value for key, value in windows.items() if key in ("five_hour", "week")})
            merged["updated"] = updated
            agy[pool] = merged
            changed = True
        if not agy:
            data.pop("agy", None)
        return changed

    _write_locked(merge)


def parse_agy_usage(text):
    pools = {}
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) != 4:
            continue
        if fields[0].startswith("Gemini Models"):
            pool = "gemini"
        elif fields[0].startswith("Claude and GPT models"):
            pool = "claude_gpt"
        else:
            continue
        if fields[1].startswith("Weekly"):
            window = "week"
        elif fields[1].startswith("Five Hour"):
            window = "five_hour"
        else:
            continue
        match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)%\s*", fields[2])
        if not match:
            continue
        try:
            resets_at = datetime.fromisoformat(fields[3].replace("Z", "+00:00")).timestamp()
        except (ValueError, OverflowError):
            continue
        pools.setdefault(pool, {})[window] = {
            "used": round(1 - float(match.group(1)) / 100, 10),
            "resets_at": resets_at,
        }
    return {pool: windows for pool, windows in pools.items() if "five_hour" in windows}


def agy_pool(model):
    if model.startswith("gemini-"):
        return "gemini"
    if model.startswith("claude-") or model.startswith("gpt-"):
        return "claude_gpt"
    return None


def agy_oldest_update(data):
    pools = data.get("agy", {})
    names = ("gemini", "claude_gpt")
    if any(name not in pools or "updated" not in pools[name] for name in names):
        return None
    return min(pools[name]["updated"] for name in names)


def agy_refresh(if_older=None, now=None):
    now = time.time() if now is None else now
    if if_older is not None:
        oldest = agy_oldest_update(load())
        if oldest is not None and now - oldest < if_older:
            return False
    command = os.environ.get("DELEGATE_AGY_BIN", "agy")
    try:
        result = subprocess.run(
            [command, "-p", "/usage"], capture_output=True, text=True,
            errors="replace", timeout=30, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if result.returncode != 0:
        return False
    pools = parse_agy_usage(result.stdout)
    if not pools:
        return False
    update_agy(pools, now)
    data = load().get("agy", {})
    return any(data.get(pool, {}).get("updated") == now for pool in pools)


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
                        payload = row.get("payload", {})
                        limits = payload.get("rate_limits")
                        if payload.get("type") != "token_count" or not limits:
                            continue
                        stamp = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).timestamp()
                        def window(value):
                            return {"used": value["used_percent"] / 100, "resets_at": value["resets_at"]}
                        found = window(limits["primary"]), window(limits["secondary"]), stamp
                    except Exception:
                        continue
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


def _agy_entry(data, item):
    if not item.startswith("agy:"):
        return None, None
    pool = agy_pool(item[4:])
    return pool, data.get("agy", {}).get(pool) if pool else None


def _vendor(item):
    return "agy" if item == "agy" or item.startswith("agy:") else item


def pick(preferred, eligible, now, data=None):
    data = load() if data is None else data
    preferred_item = preferred
    preferred_vendor = _vendor(preferred)
    preferred_pool, preferred_entry = _agy_entry(data, preferred)
    if not eligible:
        return preferred_vendor, "capability"
    if preferred == "-":
        ranked = []
        for index, item in enumerate(eligible):
            pool, agy_entry = _agy_entry(data, item)
            entry = agy_entry if item.startswith("agy:") else (None if item == "agy" else data.get(item))
            ranked.append((headroom(entry, now), -index, _vendor(item)))
        known = [item for item in ranked if item[0] is not None]
        return (max(known)[2], "quota headroom") if known else (_vendor(eligible[0]), "capability")
    entry = preferred_entry if preferred_vendor == "agy" else data.get(preferred_vendor)
    preferred_is_eligible = preferred_item in eligible or (
        preferred_vendor != "agy" and preferred_vendor in eligible
    )
    if not preferred_is_eligible or not _near(entry, now):
        return preferred_vendor, "capability"
    alternatives = []
    for item in eligible:
        vendor = _vendor(item)
        pool, candidate_agy = _agy_entry(data, item)
        candidate = candidate_agy if item.startswith("agy:") else (None if item == "agy" else data.get(vendor))
        if vendor == preferred_vendor or not candidate or _near(candidate, now):
            continue
        amount = headroom(candidate, now)
        if amount is not None:
            alternatives.append((amount, -eligible.index(item), vendor))
    if alternatives:
        vendor = max(alternatives)[2]
        if entry["five_hour"]["used"] >= .85:
            detail = f"5h at {entry['five_hour']['used']:.0%} (≥85%)"
        else:
            detail = f"week at {entry['week']['used']:.0%} (≥90%)"
        origin = f"agy/{preferred_pool}" if preferred_vendor == "agy" else preferred_vendor
        return vendor, f"switched from {origin}: {detail}"
    return preferred_vendor, f"warning: {preferred_vendor} quota near limit"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "seed":
        result = codex_from_rollout(sessions_dir=os.environ.get("DELEGATE_CODEX_SESSIONS", "~/.codex/sessions"))
        if result:
            update("codex", result[0], result[1], result[2])
        return 0
    if argv and argv[0] == "agy-refresh":
        if_older = None
        if len(argv) == 3 and argv[1] == "--if-older":
            try:
                if_older = float(argv[2])
            except ValueError:
                return 2
        elif len(argv) != 1:
            return 2
        agy_refresh(if_older=if_older)
        return 0
    if len(argv) >= 3 and argv[0] == "pick":
        eligible = argv[2:]
        if any(item == "agy" or item.startswith("agy:") for item in argv[1:]):
            agy_refresh(if_older=300)
        vendor, reason = pick(argv[1], eligible, time.time())
        print(f"{vendor}\t{reason}")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
