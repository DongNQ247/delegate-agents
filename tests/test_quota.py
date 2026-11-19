import datetime
import importlib
import json
import multiprocessing
import os
import shutil
import stat

import pytest


def module(monkeypatch, path):
    monkeypatch.setenv("DELEGATE_QUOTA", str(path))
    import quota
    return importlib.reload(quota)


def test_load_missing_and_corrupt_returns_empty(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    assert q.load() == {}
    (tmp_path / "q.json").write_text("{")
    assert q.load() == {}


def test_update_merges_vendors_and_is_atomic(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    win = {"used": .1, "resets_at": 1000}
    q.update("claude", win, win, 1)
    q.update("codex", win, win, 2)
    assert set(q.load()) == {"claude", "codex"}
    assert not list(tmp_path.glob("*.tmp"))


def test_update_ignores_older_snapshot(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    w = {"used": .1, "resets_at": 1000}
    q.update("codex", w, w, 200)
    q.update("codex", w, w, 100)
    assert q.load()["codex"]["updated"] == 200


def test_concurrent_updates_keep_valid_json(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    path = str(tmp_path / "q.json")

    def worker(vendor):
        os.environ["DELEGATE_QUOTA"] = path
        import quota
        for i in range(20):
            quota.update(vendor, {"used": .1, "resets_at": 1000}, {"used": .2, "resets_at": 2000}, i)

    processes = [multiprocessing.Process(target=worker, args=("claude" if i % 2 else "codex",)) for i in range(8)]
    for process in processes:
        process.start()
    for process in processes:
        process.join()
        assert process.exitcode == 0
    assert set(json.loads((tmp_path / "q.json").read_text())) == {"claude", "codex"}


def test_codex_from_rollout_fixture(tmp_path):
    import quota
    rollout = tmp_path / "2026" / "11" / "19" / "rollout-x-01a1f2e8.jsonl"
    rollout.parent.mkdir(parents=True)
    shutil.copy("tests/fixtures/codex-rollout-sample.jsonl", rollout)
    five_hour, week, updated = quota.codex_from_rollout(None, str(tmp_path))
    assert five_hour == {"used": .02, "resets_at": 1795089906}
    assert week == {"used": .01, "resets_at": 1795650737}
    assert updated == datetime.datetime(2026, 11, 19, 8, 24, 41, 759000, tzinfo=datetime.timezone.utc).timestamp()


def test_codex_from_rollout_none_when_absent(tmp_path):
    import quota
    assert quota.codex_from_rollout(None, str(tmp_path)) is None


def test_codex_from_rollout_skips_malformed_rate_limits_line(tmp_path):
    import quota
    path = tmp_path / "rollout.jsonl"
    path.write_text(
        '{"timestamp":"2026-11-19T08:24:41Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"resets_at":1000},"secondary":{"used_percent":34,"resets_at":2000}}}}\n'
        '{"timestamp":"bad","payload":{"type":"token_count","rate_limits":{"primary":null}}}\n'
    )
    five_hour, week, _ = quota.codex_from_rollout(sessions_dir=str(tmp_path))
    assert five_hour == {"used": .12, "resets_at": 1000}
    assert week == {"used": .34, "resets_at": 2000}


def test_headroom():
    import quota
    now = 100
    assert quota.headroom({"five_hour":{"used":.3,"resets_at":now+60},"week":{"used":.5}}, now) == .5
    assert quota.headroom({"five_hour":{"used":.3,"resets_at":99}}, now) is None
    assert quota.headroom(None, now) is None


def test_pick_capability_wins_below_threshold():
    import quota
    assert quota.pick("claude", ["claude", "codex"], 1, {"claude":{"five_hour":{"used":.84,"resets_at":10},"week":{"used":0,"resets_at":10}}})[0] == "claude"


def test_pick_unknown_preferred_keeps_capability():
    import quota
    assert quota.pick("claude", ["claude", "codex"], 1, {})[0] == "claude"


def test_pick_expired_preferred_keeps_capability():
    import quota
    data = {
        "claude": {
            "five_hour": {"used": .9, "resets_at": 99},
            "week": {"used": .1, "resets_at": 1000},
        },
        "codex": {
            "five_hour": {"used": .1, "resets_at": 1000},
            "week": {"used": .1, "resets_at": 1000},
        },
    }
    assert quota.pick("claude", ["claude", "codex"], 100, data) == ("claude", "capability")


def test_pick_switches_at_5h_085():
    import quota
    data = {"claude":{"five_hour":{"used":.85,"resets_at":100},"week":{"used":.1,"resets_at":100}}, "codex":{"five_hour":{"used":.1,"resets_at":100},"week":{"used":.1,"resets_at":100}}}
    vendor, reason = quota.pick("claude", ["claude", "codex"], 1, data)
    assert vendor == "codex"
    assert "85%" in reason and "claude" in reason


def test_pick_switches_at_week_090():
    import quota
    data = {"claude":{"five_hour":{"used":.1,"resets_at":100},"week":{"used":.9,"resets_at":100}}, "codex":{"five_hour":{"used":.1,"resets_at":100},"week":{"used":.1,"resets_at":100}}}
    assert quota.pick("claude", ["claude", "codex"], 1, data)[0] == "codex"


def test_pick_agy_is_fallback_only():
    import quota
    def ent(used):
        return {"five_hour":{"used":used,"resets_at":100},"week":{"used":used,"resets_at":100}}
    data = {"claude":ent(.9), "codex":ent(.91), "agy":{"claude_gpt":ent(.2)}}
    assert quota.pick("claude", ["claude", "codex", "agy:claude-sonnet-4-6"], 1, data)[0] == "agy"
    assert quota.pick("claude", ["claude", "codex", "agy"], 1, {"claude":ent(.9),"codex":ent(.2)})[0] == "codex"


def test_pick_no_alternative_warns():
    import quota
    ent = {"five_hour":{"used":.9,"resets_at":100},"week":{"used":.1,"resets_at":100}}
    vendor, reason = quota.pick("claude", ["claude"], 1, {"claude":ent})
    assert vendor == "claude" and reason.startswith("warning:")


def test_pick_tie_prefers_more_headroom():
    import quota
    def ent(used):
        return {"five_hour":{"used":used,"resets_at":100},"week":{"used":used,"resets_at":100}}
    assert quota.pick("-", ["codex", "claude"], 1, {"codex":ent(.1),"claude":ent(.6)})[0] == "codex"
    assert quota.pick("-", ["codex", "claude"], 1, {})[0] == "codex"


def test_cli_pick_and_seed(monkeypatch, tmp_path, capsys):
    q = module(monkeypatch, tmp_path / "q.json")
    data = {"claude":{"five_hour":{"used":.9,"resets_at":9999999999},"week":{"used":.1,"resets_at":9999999999}}, "codex":{"five_hour":{"used":.1,"resets_at":9999999999},"week":{"used":.1,"resets_at":9999999999}}}
    (tmp_path / "q.json").write_text(json.dumps(data))
    assert q.main(["pick", "claude", "claude", "codex"]) == 0
    assert capsys.readouterr().out.startswith("codex\tswitched from claude:")
    assert q.main(["seed"]) == 0
    assert capsys.readouterr().out == ""


def test_parse_agy_usage_real(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    pools = q.parse_agy_usage(open("tests/fixtures/agy-usage.txt", encoding="utf-8").read())
    assert pools["claude_gpt"]["five_hour"]["used"] == .17
    assert pools["claude_gpt"]["week"]["used"] == .08
    assert pools["gemini"]["five_hour"]["used"] == .03
    assert pools["gemini"]["week"]["used"] == .01
    assert pools["gemini"]["five_hour"]["resets_at"] == datetime.datetime(
        2026, 11, 19, 12, 4, 26, tzinfo=datetime.timezone.utc
    ).timestamp()


def test_parse_agy_usage_partial_and_garbage(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    partial = open("tests/fixtures/agy-usage-partial.txt", encoding="utf-8").read()
    assert set(q.parse_agy_usage(partial)) == {"gemini"}
    assert set(q.parse_agy_usage(partial)["gemini"]) == {"five_hour", "week"}
    assert q.parse_agy_usage(open("tests/fixtures/agy-usage-garbage.txt", encoding="utf-8").read()) == {}
    assert q.parse_agy_usage(open("tests/fixtures/agy-usage-empty.txt", encoding="utf-8").read()) == {}
    week_only = "Gemini Models\tWeekly Limit Remaining\t99%\t2026-11-26T07:04:26Z\n"
    assert q.parse_agy_usage(week_only) == {}


def test_update_agy_merges_and_keeps_others(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    codex = {"five_hour": {"used": .1, "resets_at": 1000}, "week": {"used": .2, "resets_at": 2000}}
    q.update("codex", codex["five_hour"], codex["week"], 50)
    claude_gpt = {"five_hour": {"used": .17, "resets_at": 3000}, "week": {"used": .08, "resets_at": 4000}}
    gemini = {"five_hour": {"used": .03, "resets_at": 5000}, "week": {"used": .01, "resets_at": 6000}}
    q.update_agy({"claude_gpt": claude_gpt, "gemini": gemini}, 100)
    q.update_agy({"claude_gpt": {"five_hour": {"used": .9}}}, 99)
    q.update_agy({"gemini": {"five_hour": {"used": .04}}}, 101)
    data = q.load()
    assert data["codex"]["updated"] == 50
    assert data["agy"]["claude_gpt"] == {**claude_gpt, "updated": 100}
    assert data["agy"]["gemini"]["five_hour"] == {"used": .04}
    assert "week" not in data["agy"]["gemini"]
    assert data["agy"]["gemini"]["updated"] == 101
    assert q.agy_oldest_update(data) == 100
    assert q.agy_oldest_update({"agy": {"gemini": {"updated": 101}}}) is None
    q.update_agy({"gemini": gemini}, 102)
    assert "claude_gpt" in q.load()["agy"]


def test_update_agy_drops_old_week_when_fresh_pool_has_no_week(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    q.update_agy({"gemini": {
        "five_hour": {"used": .1, "resets_at": 1000},
        "week": {"used": .8, "resets_at": 2000},
    }}, 100)

    q.update_agy({"gemini": {"five_hour": {"used": .2, "resets_at": 1100}}}, 101)

    pool = q.load()["agy"]["gemini"]
    assert pool["five_hour"] == {"used": .2, "resets_at": 1100}
    assert "week" not in pool
    assert pool["updated"] == 101


def test_agy_pool(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    assert q.agy_pool("gemini-3.8-flash-low") == "gemini"
    assert q.agy_pool("claude-sonnet-4-6") == "claude_gpt"
    assert q.agy_pool("gpt-oss-120b-medium") == "claude_gpt"
    assert q.agy_pool("foo") is None


def test_agy_refresh_cli_with_fake_bin(monkeypatch, tmp_path, capsys):
    q = module(monkeypatch, tmp_path / "q.json")
    fixed_now = datetime.datetime(2026, 11, 19, 8, 0, tzinfo=datetime.timezone.utc).timestamp()
    monkeypatch.setattr(q.time, "time", lambda: fixed_now)
    fake = tmp_path / "agy"
    fixture = os.path.abspath("tests/fixtures/agy-usage.txt")
    fake.write_text(f"#!/bin/sh\ncat '{fixture}'\n", encoding="utf-8")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("DELEGATE_AGY_BIN", str(fake))
    assert q.main(["agy-refresh"]) == 0
    assert capsys.readouterr().out == ""
    assert set(q.load()["agy"]) == {"gemini", "claude_gpt"}

    before = (tmp_path / "q.json").read_text()
    monkeypatch.setenv("DELEGATE_AGY_BIN", "/nonexistent")
    assert q.main(["agy-refresh"]) == 0
    assert (tmp_path / "q.json").read_text() == before


def test_agy_refresh_non_utf8_is_silent_and_pick_continues(monkeypatch, tmp_path, capsys):
    q = module(monkeypatch, tmp_path / "q.json")
    fake = tmp_path / "agy"
    fake.write_text("#!/bin/sh\nprintf '\\377\\376'\n", encoding="utf-8")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("DELEGATE_AGY_BIN", str(fake))

    assert q.main(["agy-refresh"]) == 0
    assert capsys.readouterr().out == ""

    assert q.main(["pick", "codex", "codex", "agy:gemini-3.8-flash-low"]) == 0
    assert capsys.readouterr().out == "codex\tcapability\n"


def test_parse_agy_usage_reworded_window_name(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    usage = "Gemini Models v2\tFive Hour Limit\t97%\t2026-11-19T12:04:26Z\n"

    pools = q.parse_agy_usage(usage)

    assert pools["gemini"]["five_hour"]["used"] == .03


def test_agy_refresh_if_older_skips_fresh(monkeypatch, tmp_path, capsys):
    q = module(monkeypatch, tmp_path / "q.json")
    q.update_agy({"claude_gpt": {"five_hour": {"used": .1}}, "gemini": {"five_hour": {"used": .2}}}, 90)
    marker = tmp_path / "ran"
    fake = tmp_path / "agy"
    fake.write_text(f"#!/bin/sh\ntouch '{marker}'\ncat tests/fixtures/agy-usage.txt\n", encoding="utf-8")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("DELEGATE_AGY_BIN", str(fake))
    monkeypatch.setattr(q.time, "time", lambda: 100)
    assert q.main(["agy-refresh", "--if-older", "300"]) == 0
    assert capsys.readouterr().out == ""
    assert not marker.exists()


def test_cli_pick_refreshes_agy_before_routing(monkeypatch, tmp_path, capsys):
    q = module(monkeypatch, tmp_path / "q.json")
    fixed_now = datetime.datetime(2026, 11, 19, 8, 0, tzinfo=datetime.timezone.utc).timestamp()
    monkeypatch.setattr(q.time, "time", lambda: fixed_now)
    data = {
        "claude": {"five_hour": {"used": .9, "resets_at": 9999999999}, "week": {"used": .1}},
        "agy": {
            "claude_gpt": {"five_hour": {"used": .9, "resets_at": 9999999999}, "week": {"used": .1}, "updated": 1},
            "gemini": {"five_hour": {"used": .1, "resets_at": 9999999999}, "week": {"used": .1}, "updated": 1},
        },
    }
    (tmp_path / "q.json").write_text(json.dumps(data))
    fixture = os.path.abspath("tests/fixtures/agy-usage.txt")
    marker = tmp_path / "ran"
    fake = tmp_path / "agy"
    fake.write_text(f"#!/bin/sh\ntouch '{marker}'\ncat '{fixture}'\n", encoding="utf-8")
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("DELEGATE_AGY_BIN", str(fake))
    assert q.main(["pick", "claude", "claude", "agy:gemini-3.8-flash-low"]) == 0
    assert marker.exists()
    output = capsys.readouterr().out
    assert output.startswith("agy\tswitched from claude:")


def test_pick_agy_switch_target_by_pool(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    data = {
        "claude": {"five_hour": {"used": .9, "resets_at": 100}, "week": {"used": .1}},
        "agy": {"claude_gpt": {"five_hour": {"used": .2, "resets_at": 100}, "week": {"used": .1}}},
    }
    assert q.pick("claude", ["claude", "agy:claude-sonnet-4-6"], 1, data)[0] == "agy"


def test_pick_agy_unknown_never_target(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    data = {"claude": {"five_hour": {"used": .9, "resets_at": 100}, "week": {"used": .1}}}
    for unknown in ("agy:foo", "agy"):
        vendor, reason = q.pick("claude", ["claude", unknown], 1, data)
        assert vendor == "claude"
        assert reason.startswith("warning:")


def test_pick_preferred_agy_near_limit_switches(monkeypatch, tmp_path):
    q = module(monkeypatch, tmp_path / "q.json")
    data = {
        "agy": {"gemini": {"five_hour": {"used": .9, "resets_at": 100}, "week": {"used": .1}}},
        "codex": {"five_hour": {"used": .1, "resets_at": 100}, "week": {"used": .1}},
    }
    vendor, reason = q.pick("agy:gemini-3.8-flash-low", ["agy:gemini-3.8-flash-low", "codex"], 1, data)
    assert vendor == "codex"
    assert "agy/gemini" in reason
