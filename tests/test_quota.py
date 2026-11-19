import datetime
import importlib
import json
import multiprocessing
import os
import shutil

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
    assert quota.pick("claude", ["claude", "codex", "agy"], 1, {"claude":ent(.9),"codex":ent(.91)})[0] == "agy"
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
